import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_reader.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/ui/theme.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test/support/epub_fixture.dart';

void verifyNativeEpubPerformance() {
  testWidgets(
    'native default EPUB survives rapid turns and renderer interruption',
    (tester) async {
      await Strings.initialize();
      final directory = await Directory.systemTemp.createTemp('epub-stress-');
      final store = LocalStore(sqlite3.openInMemory());
      const profile = ServerProfile(
        id: 'epub-stress',
        name: 'Fixture',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.apiKey,
      );
      final repository = Repository(
        profile: profile,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: profile.authentication,
          credential: '',
        ),
        store: store,
        directory: directory,
      )..setOffline(true);
      final book = Book({
        'id': 'stress',
        'name': 'Long chapter',
        'media': {'mediaProfile': 'EPUB'},
      });
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 180; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (ready()) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail(
          'Default EPUB did not settle: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' | ')}',
        );
      }

      InAppWebViewController? controller() {
        // Public diagnostic getter avoids replacing the production native view.
        final dynamic state = tester.state(find.byType(BrowserEpubReader));
        return state.browserController as InAppWebViewController?;
      }

      Future<dynamic> js(String source) async {
        final result = await controller()!
            .callAsyncJavaScript(functionBody: source)
            .timeout(const Duration(seconds: 20));
        expect(result?.error, isNull);
        return result?.value;
      }

      Future<void> visibleText() async {
        // Native bounds, DOM repagination and raster delivery are independent.
        // Wait for the actual surface size and layout instead of assuming a
        // fixed 300ms is sufficient on a software-rendered emulator.
        var settled = false;
        for (var attempt = 0; attempt < 60; attempt++) {
          final expected = tester.getSize(find.byType(InAppWebView));
          final geometry = object(
            await js(
              'return {width:innerWidth,height:innerHeight,ready:reader.layoutReady()};',
            ),
          );
          if (geometry['ready'] == true &&
              ((geometry['width'] as num).toDouble() - expected.width).abs() <
                  2 &&
              ((geometry['height'] as num).toDouble() - expected.height).abs() <
                  2) {
            settled = true;
            break;
          }
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          settled,
          true,
          reason: 'Native WebView bounds and EPUB layout must settle',
        );
        await js('await reader.whenIdle();return true;');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        for (final view in tester.binding.renderViews) {
          view.markNeedsPaint();
        }
        await tester.pump(const Duration(milliseconds: 100));
        ui.Image image;
        if (Platform.isAndroid) {
          Uint8List? bytes;
          for (var attempt = 0; attempt < 5; attempt++) {
            try {
              bytes = await ReaderDisplay.channel.invokeMethod<Uint8List>(
                'captureScreenshot',
              );
              break;
            } on PlatformException catch (error) {
              if (error.code != 'Could not copy the pixels' ||
                  error.message != 'result was 3' ||
                  attempt == 4) {
                rethrow;
              }
              for (final view in tester.binding.renderViews) {
                view.markNeedsPaint();
              }
              await tester.pump(const Duration(milliseconds: 250));
            }
          }
          expect(bytes, isNotEmpty);
          final codec = await ui.instantiateImageCodec(bytes!);
          image = (await codec.getNextFrame()).image;
          codec.dispose();
        } else {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find
                .ancestor(
                  of: find.byType(InAppWebView),
                  matching: find.byType(RepaintBoundary),
                )
                .first,
          );
          image = await boundary.toImage();
        }
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var dark = 0;
          // Ignore window controls/bars; the center must contain actual glyphs.
          for (var y = image.height ~/ 4; y < image.height * 3 ~/ 4; y++) {
            for (var x = image.width ~/ 4; x < image.width * 3 ~/ 4; x++) {
              final index = (y * image.width + x) * 4;
              if (data.getUint8(index) < 120 &&
                  data.getUint8(index + 1) < 120 &&
                  data.getUint8(index + 2) < 120) {
                dark++;
              }
            }
          }
          expect(
            dark,
            greaterThan(150),
            reason: 'The native reader surface must render text, not only report a DOM locator',
          );
        } finally {
          image.dispose();
        }
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: ReaderDisplay(
              child: BrowserEpubReader(
                file: fixture(directory, paragraphCount: 1400),
                repository: repository,
                book: book,
              ),
            ),
          ),
        );
        await waitFor(
          () =>
              find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              controller() != null,
        );
        final view = tester.widget<InAppWebView>(find.byType(InAppWebView));
        final initial = await js('return reader.position().start.cfi;');
        await js(
          '''window.turnArguments=[]; window.completedTurns=0; const turn=reader.turn;
        reader.turn=async value=>{turnArguments.push(value); await turn(value); completedTurns++; return true;}; return true;''',
        );
        for (var i = 0; i < 6; i++) {
          await tester.tap(find.byTooltip('Next Page'));
          await tester.pump(const Duration(milliseconds: 10));
        }
        await waitFor(
          () =>
              object(store.cached(profile.id, 'epub:${book.id}'))['cfi'] !=
              null,
        );
        expect(await js('return reader.position().start.cfi;'), isNot(initial));
        for (var i = 0; i < 100; i++) {
          if (await js('return completedTurns;') == 6) break;
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await js('return completedTurns;'), 6);
        expect(await js('return turnArguments.length;'), 6);
        expect(
          await js(
            'return turnArguments.every(v=>!Object.hasOwn(v,"snapshot"));',
          ),
          true,
        );
        expect(
          identical(
            view,
            tester.widget<InAppWebView>(find.byType(InAppWebView)),
          ),
          true,
          reason: 'Locator updates must retain the native WebView widget',
        );
        // Hiding controls must move the existing surface, never dispose it.
        final retainedController = controller();
        var readingAnchor = await js('return reader.position().start.cfi;');
        for (var i = 0; i < 2; i++) {
          await js(
            "const frame=document.querySelector('#viewer iframe'),doc=frame.contentDocument,b=frame.getBoundingClientRect();doc.body.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:innerWidth/2-b.left,clientY:innerHeight/2-b.top}));return true;",
          );
          if (Platform.isWindows) {
            await tester.tapAt(
              tester.getCenter(find.byType(InAppWebView)),
              kind: PointerDeviceKind.mouse,
            );
            await tester.pump(const Duration(milliseconds: 200));
            expect(find.byTooltip('Next Page'), findsOneWidget);
            expect(
              await ReaderDisplay.channel.invokeMethod<bool>('getFullscreen'),
              false,
            );
            expect(
              await js(
                "return document.querySelector('#viewer iframe').contentDocument.getSelection().isCollapsed;",
              ),
              true,
            );
            final beforeArrow = await js('return reader.position().start.cfi;');
            final beforeCount = (await js('return completedTurns;') as num)
                .toInt();
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            for (var attempt = 0; attempt < 30; attempt++) {
              await tester.pump(const Duration(milliseconds: 100));
              if (await js('return reader.position().start.cfi;') !=
                  beforeArrow) {
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(
              await js('return reader.position().start.cfi;'),
              isNot(beforeArrow),
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            for (var attempt = 0; attempt < 50; attempt++) {
              await tester.pump(const Duration(milliseconds: 100));
              if (await js('return completedTurns;') == beforeCount + 2) break;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(await js('return completedTurns;'), beforeCount + 2);
            await js('await reader.whenIdle();return true;');
            readingAnchor = await js('return reader.position().start.cfi;');
          } else {
            await waitFor(() => find.byTooltip('Next Page').evaluate().isEmpty);
          }
          expect(identical(controller(), retainedController), true);
          await visibleText();
          await js(
            "document.querySelector('#viewer iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true;",
          );
          await waitFor(
            () => find.byTooltip('Next Page').evaluate().isNotEmpty,
          );
          await tester.tap(find.byTooltip('Full Screen'));
          await waitFor(() => find.byTooltip('Next Page').evaluate().isEmpty);
          if (Platform.isWindows) {
            expect(
              await ReaderDisplay.channel.invokeMethod<bool>('getFullscreen'),
              true,
            );
          }
          expect(identical(controller(), retainedController), true);
          await visibleText();
          await js(
            "document.querySelector('#viewer iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true;",
          );
          await waitFor(
            () => find.byTooltip('Next Page').evaluate().isNotEmpty,
          );
          if (Platform.isWindows) {
            expect(
              await ReaderDisplay.channel.invokeMethod<bool>('getFullscreen'),
              false,
            );
          }
          await visibleText();
          expect(
            await js('return reader.position().start.cfi;'),
            readingAnchor,
          );
        }
        // Exercise the real WebView GPU/texture path, not only headless Chrome.
        expect(
          await js("""
          // Emulator accessibility disables animation. Exercise actual GPU
          // pixels in this scoped branch, then restore the media query.
          window.nativeMedia=window.matchMedia;
          window.matchMedia=query=>query.includes('prefers-reduced-motion')?{matches:false}:nativeMedia.call(window,query);
          window.nativeStart=KMReaderSheetEffect.prototype.start;
          window.nativeAnimate=KMReaderSheetEffect.prototype.animateTo;
          KMReaderSheetEffect.prototype.start=async function(move){window.nativeCurl=this;return nativeStart.call(this,move);};
          KMReaderSheetEffect.prototype.animateTo=function(){return new Promise(()=>{});};
          await reader.turn({delta:1,style:'curl'});
          if(!window.nativeCurl)throw Error('GPU effect did not start: supported='+KMReaderSheetEffect.supported('curl')+', reduced='+matchMedia('(prefers-reduced-motion: reduce)').matches);
          if(!nativeCurl.surface||!document.getElementById('page-curl-surface'))throw Error('Native GPU curl unavailable');
          nativeCurl.update(.5,{x:innerWidth*.5,y:innerHeight*.25});
          return nativeCurl.surface.canvas.width>=innerWidth;
        """),
          true,
        );
        await visibleText();
        await js("""
          nativeCurl.stop();window.matchMedia=nativeMedia;KMReaderSheetEffect.prototype.start=nativeStart;
          KMReaderSheetEffect.prototype.animateTo=nativeAnimate;
          await reader.previous();return true;
        """);
        // The action must retain its selected passage even if native focus
        // clears the DOM selection while the toolbar popup is open.
        final selected = await js("""
          const frame=document.querySelector('#viewer iframe'),doc=frame.contentDocument,b=frame.getBoundingClientRect();
          const paragraph=[...doc.querySelectorAll('p')].find(p=>[...p.getClientRects()].some(r=>r.right+b.left>0&&r.left+b.left<innerWidth&&r.bottom+b.top>0&&r.top+b.top<innerHeight));
          window.selectionParagraph=paragraph;doc.getSelection().selectAllChildren(paragraph);return paragraph.textContent;
        """);
        final dynamic selectionState = tester.state(
          find.byType(BrowserEpubReader),
        );
        await waitFor(() => selectionState.selectedText == selected);
        if (Platform.isWindows) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await waitFor(() => selectionState.selectedText == '');
          expect(
            find.byType(BrowserEpubReader),
            findsOneWidget,
            reason: 'Escape clears text selection before leaving a book',
          );
          await js(
            'selectionParagraph.ownerDocument.getSelection().selectAllChildren(selectionParagraph);return true;',
          );
          await waitFor(() => selectionState.selectedText == selected);
        }
        await tester.tap(find.byType(PopupMenuButton<String>).first);
        await tester.pumpAndSettle();
        expect(find.text('Translate Selected Text'), findsOneWidget);
        await js(
          "document.querySelector('#viewer iframe').contentDocument.getSelection().removeAllRanges();return true;",
        );
        await waitFor(() => selectionState.selectedText == '');
        await tester.tap(find.text('Translate Selected Text'));
        await tester.pumpAndSettle();
        expect(find.text(selected as String), findsOneWidget);
        await tester.tap(find.byType(BackButton).last);
        await tester.pumpAndSettle();
        await visibleText();
        final result = object(
          await js('''const times=[];
        for(let i=0;i<48;i++) { const old=reader.position().start.cfi, at=performance.now();
          await reader.turn({delta:1,style:'slide'}); times.push(performance.now()-at);
          if(reader.position().start.cfi===old) throw new Error('Page did not advance '+i);
        } times.sort((a,b)=>a-b); return {median:times[24],max:times[47]};'''),
        );
        debugPrint(
          'Native EPUB command latency (debug engine, not device FPS): $result',
        );
        await visibleText();
        if (Platform.isWindows) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          await tester.pump();
          final saved = object(
            store.cached(profile.id, 'epub:${book.id}'),
          )['cfi'];
          final oldController = controller();
          // Exercise a real WebView2 renderer exit, not a simulated Dart event.
          unawaited(
            oldController!
                .callDevToolsProtocolMethod(methodName: 'Page.crash')
                .timeout(const Duration(seconds: 3))
                .then<void>((_) {}, onError: (Object _) {}),
          );
          await waitFor(
            () =>
                controller() != null &&
                !identical(oldController, controller()) &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty,
          );
          expect(await js('return reader.position().start.cfi;'), saved);
          await visibleText();
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pump();
        repository.dispose();
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
