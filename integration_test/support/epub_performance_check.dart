import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
        await Future<void>.delayed(const Duration(milliseconds: 200));
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
        final readingAnchor = await js('return reader.position().start.cfi;');
        for (var i = 0; i < 2; i++) {
          await js(
            "const frame=document.querySelector('#viewer iframe'),doc=frame.contentDocument,b=frame.getBoundingClientRect();doc.body.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:innerWidth/2-b.left,clientY:innerHeight/2-b.top}));return true;",
          );
          await waitFor(() => find.byTooltip('Next Page').evaluate().isEmpty);
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
