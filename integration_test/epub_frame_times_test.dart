// Run with --profile on an interactive desktop. These are renderer diagnostics,
// not an estimate of frames physically presented by the monitor.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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

import '../test/support/epub_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('EPUB frame diagnostics with natural native presentation', (
    tester,
  ) async {
    expect(Platform.isWindows, true);
    expect(kProfileMode, true, reason: 'Measure with --profile, not debug.');
    await Strings.initialize();
    final directory = await Directory.systemTemp.createTemp(
      'epub-frame-times-',
    );
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'frame-times',
      name: 'Synthetic fixture',
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
    final navigator = GlobalKey<NavigatorState>();
    final readerKey = GlobalKey();
    final external = Platform.environment['KMREADER_PROFILE_EPUB'];
    final publication = external == null
        ? fixture(directory, paragraphCount: 1400)
        : File(external);
    final publicationBytes = await publication.readAsBytes();
    final results = <String, dynamic>{
      'schema': 1,
      'mode': 'profile',
      'source': Platform.environment['GITHUB_SHA'],
      'publication': {
        'kind': external == null ? 'generated' : 'external',
        'paragraphsPerChapter': external == null ? 1400 : null,
        'bytes': publicationBytes.length,
        'sha256': sha256.convert(publicationBytes).toString(),
      },
      'notes':
          'WebView RAF, capture delivery and Flutter renderer timings; '
          'not physical monitor presentation FPS. No synthetic 16ms pumping.',
    };
    final phases = <String, dynamic>{};
    results['phases'] = phases;
    binding.reportData = results;
    InAppWebViewController controller() =>
        (readerKey.currentState as dynamic).browserController
            as InAppWebViewController;
    Future<dynamic> js(String source) async {
      final reply = await controller()
          .callAsyncJavaScript(functionBody: source)
          .timeout(const Duration(seconds: 45));
      if (reply?.error != null) throw StateError('${reply!.error}');
      return reply?.value;
    }

    Future<void> ready() async {
      for (var i = 0; i < 300; i++) {
        final dynamic state = readerKey.currentState;
        if (state?.browserController != null) {
          try {
            if (await js(
                  'return typeof reader!=="undefined" && reader.layoutReady();',
                ) ==
                true) {
              await js('await reader.whenIdle();return true;');
              return;
            }
          } catch (_) {
            // Initial navigation can replace the provisional document.
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('Native EPUB did not finish opening.');
    }

    Future<Map<String, dynamic>> captureStats() async =>
        (await MethodChannel(
          'com.pichillilorenzo/custom_platform_view_${controller().getViewId()}',
        ).invokeMapMethod<String, dynamic>('getRenderingStats')) ??
        {};

    Future<void> measure(
      String name,
      Future<void> Function() action, {
      bool browser = true,
    }) async {
      // Flush batched FrameTiming callbacks from the preceding phase.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final before = browser ? await captureStats() : null;
      if (browser) {
        await js('''
          window.kmFrameProbe={intervals:[],previous:null,hidden:document.hidden,active:true};
          const probe=kmFrameProbe,raf=requestAnimationFrame.bind(window);
          const sample=now=>{
            if(!probe.active)return;
            probe.hidden ||= document.hidden;
            if(probe.previous!==null)probe.intervals.push(now-probe.previous);
            probe.previous=now;raf(sample);
          };raf(sample);return true;
        ''');
      }
      final frames = <ui.FrameTiming>[];
      void collect(List<ui.FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(collect);
      final clock = Stopwatch()..start();
      dynamic browserFrames;
      Map<String, dynamic>? after;
      try {
        await action();
        clock.stop();
        if (browser) {
          browserFrames = await js(
            'kmFrameProbe.active=false;return kmFrameProbe;',
          );
          after = await captureStats();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(collect);
      }
      phases[name] = {
        'actionElapsedMs': clock.elapsedMicroseconds / 1000,
        'webViewRaf': browserFrames,
        'captureBefore': before,
        'captureAfter': after,
        'flutterBuildMs': frames
            .map((f) => f.buildDuration.inMicroseconds / 1000)
            .toList(),
        'flutterRasterMs': frames
            .map((f) => f.rasterDuration.inMicroseconds / 1000)
            .toList(),
        'flutterTotalSpanMs': frames
            .map((f) => f.totalSpan.inMicroseconds / 1000)
            .toList(),
        'flutterVsyncMicros': frames
            .map((f) => f.timestampInMicroseconds(ui.FramePhase.vsyncStart))
            .toList(),
      };
      // Keep partial results if a later phase fails, without uploading books.
      debugPrint(
        'EPUB frame phase $name: ${frames.length} Flutter frames, '
        '${clock.elapsedMilliseconds}ms action',
      );
      if (browser) {
        expect((browserFrames as Map)['hidden'], false);
        expect(browserFrames['intervals'], isNotEmpty);
        expect(
          after!['captures'],
          greaterThanOrEqualTo(before!['captures'] as num),
        );
      }
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: appTheme(Brightness.light),
          home: const Scaffold(
            body: Center(child: Text('Frame-time baseline')),
          ),
        ),
      );
      await tester.runAsync(() async {
        await measure('flutterSheetBaseline', () async {
          for (var i = 0; i < 3; i++) {
            final sheet = showModalBottomSheet<void>(
              context: navigator.currentContext!,
              builder: (_) => const SizedBox(
                height: 400,
                child: Center(child: Text('Baseline sheet')),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 450));
            navigator.currentState!.pop();
            await sheet;
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
        }, browser: false);
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: appTheme(Brightness.light),
          home: ReaderDisplay(
            keepAwake: true,
            child: BrowserEpubReader(
              key: readerKey,
              file: publication,
              repository: repository,
              book: Book({
                'id': 'frames',
                'name': 'Synthetic long chapter',
                'media': {'mediaProfile': 'EPUB'},
              }),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await ready();
        results['browser'] = await js(
          'return {width:innerWidth,height:innerHeight,dpr:devicePixelRatio,userAgent:navigator.userAgent,reducedMotion:matchMedia("(prefers-reduced-motion: reduce)").matches};',
        );
        expect(
          (results['browser'] as Map)['reducedMotion'],
          false,
          reason: 'Enable Windows animation effects for the motion benchmark.',
        );
        await measure(
          'idle',
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        await js('''
          const original=KMReaderSheetEffect.prototype.animateTo;
          KMReaderSheetEffect.prototype.animateTo=function(...args){
            window.kmMeasuredEffect=this;
            return window.kmMeasuredFlight=original.apply(this,args);
          };return true;
        ''');
        final preferences = jsonEncode(const EpubPreferences().toJson());
        for (final style in ['slide', 'curl']) {
          await js(
            'await reader.preferences({...$preferences,transition:"$style"});await reader.whenIdle();return true;',
          );
          // Warm the real capture/compositor path before recording four turns.
          await js(
            'window.kmMeasuredEffect=null;window.kmMeasuredFlight=null;await reader.turn({delta:1,style:"$style"});if(!kmMeasuredFlight)throw Error("Motion warmup unavailable");await kmMeasuredFlight;return true;',
          );
          await measure(style, () async {
            await js('''
              let changed=0;
              for(let i=0;i<4;i++){
                const before=reader.position().start.cfi;
                window.kmMeasuredEffect=null;window.kmMeasuredFlight=null;
                await reader.turn({delta:1,style:'$style'});
                if(!window.kmMeasuredEffect||kmMeasuredEffect.style!=='$style')throw Error('Motion path unavailable');
                await kmMeasuredFlight;
                if(reader.position().start.cfi!==before)changed++;
                await new Promise(requestAnimationFrame);
              }
              if(changed!==4)throw Error('Expected four real page turns: '+changed);
              return true;
            ''');
          });
          if (style == 'curl') {
            results['webGlRenderer'] = await js('''
              const gl=KMReaderCurlSurface.shared.gl,extension=gl.getExtension('WEBGL_debug_renderer_info');
              return {renderer:gl.getParameter(gl.RENDERER),unmasked:extension?gl.getParameter(extension.UNMASKED_RENDERER_WEBGL):null};
            ''');
          }
        }
        await js(
          'await reader.preferences({...$preferences,flow:"scrolled"});await reader.whenIdle();return true;',
        );
        await measure('verticalScroll', () async {
          final moved = await js('''
            const viewport=document.querySelector('.epub-container'),base=viewport.scrollTop;
            let first=null,min=base,max=base;
            await new Promise(resolve=>{
              const step=now=>{
                first??=now;const elapsed=now-first;
                viewport.scrollTop=base+500*(1-Math.cos(Math.PI*elapsed/1500));
                min=Math.min(min,viewport.scrollTop);max=Math.max(max,viewport.scrollTop);
                if(elapsed<3000)requestAnimationFrame(step);else resolve();
              };requestAnimationFrame(step);
            });return max-min;
          ''');
          expect(moved as num, greaterThan(100));
        });
        await measure('readerSettings', () async {
          for (var i = 0; i < 3; i++) {
            // Reveal normal controls, then invoke the real settings menu action.
            await js(
              "document.querySelector('#viewer iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true;",
            );
            final deadline = Stopwatch()..start();
            while (find.byType(PopupMenuButton<String>).evaluate().isEmpty &&
                deadline.elapsedMilliseconds < 5000) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            final popup = tester.widget<PopupMenuButton<String>>(
              find.byType(PopupMenuButton<String>).first,
            );
            popup.onSelected!('settings');
            await Future<void>.delayed(const Duration(milliseconds: 700));
            expect(find.byType(BottomSheet), findsOneWidget);
            navigator.currentState!.pop();
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        });
      });
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      repository.dispose();
      store.close();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
