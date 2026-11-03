import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_reader.dart';
import 'package:kmreader/features/reader/epub_session.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/ui/theme.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test/support/epub_fixture.dart';

void verifyNativeEpubRecovery() {
  testWidgets(
    'Android EPUB restores visible text after GPU faults and cold reader reopen',
    (tester) async {
      await Strings.initialize();
      final directory = await Directory.systemTemp.createTemp('epub-recovery-');
      final store = LocalStore(sqlite3.openInMemory());
      const profile = ServerProfile(
        id: 'epub-recovery',
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
        'id': 'recovery',
        'name': 'EPUB recovery fixture',
        'media': {'mediaProfile': 'EPUB'},
      });
      // Start a fresh native WebView with saved curl, including idle GPU work.
      store.cache(
        profile.id,
        'epub:${book.id}',
        EpubPreferences.fromJson({'theme': 'white', 'transition': 'curl'})
            .toJson(),
      );
      final file = fixture(directory, paragraphCount: 1400);
      InAppWebViewController? controller() {
        if (find.byType(BrowserEpubReader).evaluate().isEmpty) return null;
        final dynamic state = tester.state(find.byType(BrowserEpubReader));
        return state.browserController as InAppWebViewController?;
      }

      Future<dynamic> js(String source) async {
        var finished = false;
        final reply = controller()!
            .callAsyncJavaScript(functionBody: source)
            .timeout(const Duration(seconds: 30))
            .whenComplete(() => finished = true);
        // Deliver actual Android texture frames while JS waits for RAF.
        while (!finished) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        final result = await reply;
        expect(result?.error, isNull);
        return result?.value;
      }

      Future<void> mount() async {
        await tester.pumpWidget(
          MaterialApp(
            initialRoute: '/',
            theme: appTheme(Brightness.light),
            home: ReaderDisplay(
              keepAwake: true,
              child: BrowserEpubReader(
                file: file,
                repository: repository,
                book: book,
              ),
            ),
          ),
        );
        for (var i = 0; i < 180; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (controller() != null &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
        }
        fail('Cold Android EPUB did not become ready');
      }

      Future<void> readable(String phase) async {
        expect(
          await js('''
          await reader.whenIdle();
          return reader.layoutReady() && !document.querySelector('#page-curl-surface,style[data-page-motion],#page-gesture');
        '''),
          true,
        );
        // DOM/CFI success alone missed the original invisible-text failure.
        for (final view in tester.binding.renderViews) {
          view.markNeedsPaint();
        }
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        Uint8List? bytes;
        for (var attempt = 0; attempt < 5; attempt++) {
          try {
            bytes = await ReaderDisplay.channel.invokeMethod<Uint8List>(
              'captureScreenshot',
            );
            break;
          } on PlatformException catch (error) {
            final pendingFrame =
                error.code == 'capture_failed' &&
                    error.message == 'PixelCopy failed: 3' ||
                error.code == 'Could not copy the pixels' &&
                    error.message == 'result was 3';
            if (attempt == 4 || !pendingFrame) {
              rethrow;
            }
            await tester.pump(const Duration(milliseconds: 250));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(bytes, isNotEmpty);
        final report =
            IntegrationTestWidgetsFlutterBinding.ensureInitialized()
                    .reportData ??=
                <String, dynamic>{};
        (report.putIfAbsent(
          'epubRecoveryScreenshots',
          () => <Map<String, dynamic>>[],
        ) as List).add({'phase': phase, 'png': base64Encode(bytes!)});
        final dom = await js('''
          return {width:innerWidth,height:innerHeight,hidden:document.hidden,userAgent:navigator.userAgent,
            frames:[...document.querySelectorAll('#viewer iframe')].map(f=>({
              frame:f.getBoundingClientRect().toJSON(),body:f.contentDocument.body.getBoundingClientRect().toJSON(),
              textLength:f.contentDocument.body.textContent.length,
              color:f.contentWindow.getComputedStyle(f.contentDocument.body).color
            }))};
        ''');
        final native = await ReaderDisplay.channel
            .invokeMapMethod<String, dynamic>('getWebViewRenderingStats');
        final configuration = await ReaderDisplay.channel
            .invokeMapMethod<String, dynamic>('getEpubWebViewConfiguration');
        final probe = <String, dynamic>{
          'phase': phase,
          'dom': dom,
          'native': native,
          'impellerRequested': configuration?['impellerRequested'],
          'compositionOverride':
              const bool.hasEnvironment('KMREADER_EPUB_HYBRID_COMPOSITION') ||
              configuration?['diagnosticOverride'] == true,
          'hybrid': tester
              .widget<InAppWebView>(find.byType(InAppWebView))
              .platform
              .params
              .initialSettings
              ?.useHybridComposition,
        };
        (report.putIfAbsent(
          'epubRecoveryProbes',
          () => <Map<String, dynamic>>[],
        ) as List).add(probe);
        debugPrint('EPUB visible-text probe: ${jsonEncode(probe)}');
        // PixelCopy already captured the actual app surface. Decode its PNG
        // on CPU: ui.Image.toByteData adds an unrelated Impeller GPU blit that
        // crashed the Mate 20's IO thread during this verification itself.
        final image = img.decodePng(bytes)!;
        var dark = 0, light = 0;
        final pixels = image.getRange(
          image.width ~/ 4,
          image.height ~/ 4,
          image.width ~/ 2,
          image.height ~/ 2,
        );
        while (pixels.moveNext()) {
          final pixel = pixels.current;
          final r = pixel.r, g = pixel.g, b = pixel.b;
          if (r < 120 && g < 120 && b < 120) dark++;
          if (r > 180 && g > 180 && b > 180) light++;
        }
        probe.addAll({
          'darkPixels': dark,
          'lightPixels': light,
          'imageWidth': image.width,
          'imageHeight': image.height,
        });
        expect(
          dark,
          greaterThan(150),
          reason: 'Android must deliver visible glyphs',
        );
        expect(
          light,
          greaterThan(150),
          reason: 'A black texture is not readable text',
        );
      }

      try {
        await mount();
        await readable('cold-open');
        final beforeSettings = await js('return reader.position().start.cfi;');
        await tester.tap(find.byType(PopupMenuButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Text Settings').last);
        await tester.pumpAndSettle();
        expect(find.text('Text Settings'), findsWidgets);
        await tester.tap(find.byTooltip('Close').last);
        await tester.pumpAndSettle();
        expect(await js('return reader.position().start.cfi;'), beforeSettings);
        await readable('settings-close');
        final normalCurl = await js('''
          const media=window.matchMedia,start=KMReaderSheetEffect.prototype.start,animate=KMReaderSheetEffect.prototype.animateTo;
          window.matchMedia=q=>q.includes('prefers-reduced-motion')?{matches:false}:media.call(window,q);
          let effect;
          KMReaderSheetEffect.prototype.start=function(...args){effect=this;return start.apply(this,args);};
          KMReaderSheetEffect.prototype.animateTo=function(target,duration,options){return animate.call(this,target,900,options);};
          try{
            const before=reader.position().start.cfi,started=performance.now();
            await reader.turn({delta:1,style:'curl'});
            const ready=performance.now();
            if(!effect?.surface)throw Error('Normal native GPU curl did not start');
            const samples=[],deadline=ready+4000;
            while(!effect.stopped){
              samples.push({time:performance.now()-ready,progress:effect.progress});
              if(performance.now()>deadline)throw Error('Normal native curl did not finish');
              await new Promise(resolve=>setTimeout(resolve,16));
            }
            if(effect.failed||effect.progress<.999)throw Error('Normal native curl fell back before completion');
            if(new Set(samples.filter(s=>s.progress>0&&s.progress<1).map(s=>s.progress)).size<2)throw Error('Normal native curl had no intermediate frames');
            if(effect.surface.gl.getError()!==effect.surface.gl.NO_ERROR)throw Error('Native curl reported a GPU drawing error');
            if(reader.position().start.cfi===before)throw Error('Normal native curl did not navigate');
            return {configuredDurationMs:900,readyMs:ready-started,durationMs:performance.now()-ready,samples};
          }finally{window.matchMedia=media;KMReaderSheetEffect.prototype.start=start;KMReaderSheetEffect.prototype.animateTo=animate;}
        ''');
        IntegrationTestWidgetsFlutterBinding.ensureInitialized()
                .reportData!['normalCurl'] =
            normalCurl;
        await readable('normal-curl');
        // Scope forced motion to the probe: CI/emulator accessibility can
        // disable animations; the production preference remains untouched.
        expect(
          await js('''
          window.recoveryMedia=window.matchMedia;
          window.matchMedia=q=>q.includes('prefers-reduced-motion')?{matches:false}:recoveryMedia.call(window,q);
          window.recoveryStart=KMReaderSheetEffect.prototype.start;
          KMReaderSheetEffect.prototype.start=function(...args){window.recoveryEffect=this;return recoveryStart.apply(this,args);};
          const render=KMReaderCurlSurface.prototype.render;
          let injected=false;
          KMReaderCurlSurface.prototype.render=function(p,...args){
            if(p>0&&p<1&&window.recoveryEffect?.surface===this){injected=true;throw Error('Injected Android GPU draw failure');}
            return render.call(this,p,...args);
          };
          const before=reader.position().start.cfi;
          try{
            await reader.turn({delta:1,style:'curl'});
            if(!window.recoveryEffect?.surface)throw Error('Native curl path was unavailable');
            const deadline=performance.now()+4000;
            while(!recoveryEffect.stopped){
              if(performance.now()>deadline)throw Error('Failed Android draw retained its overlay');
              await new Promise(resolve=>setTimeout(resolve,16));
            }
            if(!recoveryEffect.failed||KMReaderSheetEffect.supported('curl'))throw Error('Fault was not recovered');
            return injected && reader.position().start.cfi!==before;
          }finally{KMReaderCurlSurface.prototype.render=render;}
        '''),
          true,
        );
        await readable('draw-failure');
        expect(
          await js('''
          const before=reader.position().start.cfi;
          await reader.turn({delta:1,style:'curl'});
          return reader.position().start.cfi!==before;
        '''),
          true,
        );
        await readable('direct-turn');
        final saved = await js('return reader.position().start.cfi;');
        // Destroy the native WebView and session, then load from persisted CFI
        // with the same saved curl preferences (a JS display() is insufficient).
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(
          object(store.cached(profile.id, 'epub:${book.id}'))['cfi'],
          saved,
        );
        await mount();
        expect(await js('return reader.position().start.cfi;'), saved);
        await readable('reader-reopen');
        expect(
          await js('''
          const media=window.matchMedia;
          window.matchMedia=q=>q.includes('prefers-reduced-motion')?{matches:false}:media.call(window,q);
          const animate=KMReaderSheetEffect.prototype.animateTo;
          let lost=false;
          KMReaderSheetEffect.prototype.animateTo=function(...args){
            window.recoveryEffect=this;
            const flight=animate.apply(this,args);
            const extension=this.surface?.gl.getExtension('WEBGL_lose_context');
            if(!extension)throw Error('Native context-loss probe unavailable');
            extension.loseContext();lost=true;return flight;
          };
          try{
            await reader.turn({delta:1,style:'curl'});
            const deadline=performance.now()+4000;
            while(!window.recoveryEffect?.stopped){
              if(performance.now()>deadline)throw Error('Context loss retained the Android overlay');
              await new Promise(resolve=>setTimeout(resolve,16));
            }
            return lost && recoveryEffect.failed && !KMReaderSheetEffect.supported('curl');
          }finally{KMReaderSheetEffect.prototype.animateTo=animate;window.matchMedia=media;}
        '''),
          true,
        );
        await readable('context-loss');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 500));
        repository.dispose();
        store.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isAndroid,
  );
}
