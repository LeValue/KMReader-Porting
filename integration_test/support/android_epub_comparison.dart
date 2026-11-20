import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_host.dart';
import 'package:kmreader/features/reader/epub_reader.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test/support/epub_fixture.dart';

void verifyAndroidEpubComparison() {
  testWidgets('same-device Android before and after EPUB timing', (
    tester,
  ) async {
    ByteData baseline;
    try {
      baseline = await rootBundle.load('assets/epub/benchmark-baseline.js');
    } on FlutterError {
      markTestSkipped('This diagnostic requires the build 42 browser asset.');
      return;
    }
    await Strings.initialize();
    final binding = tester.binding as IntegrationTestWidgetsFlutterBinding;
    final policy = binding.framePolicy;
    final dir = Directory.systemTemp.createTempSync('epub-compare-');
    String chapter(int number) =>
        '''
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $number</title>
      <style>img{width:70%;height:auto} p{margin:.5em 0}
      ${List.generate(24, (i) => '.frame$i {background-image:url(illustration.svg)}').join('\n')}
      </style></head><body>
      ${List.generate(number == 1 ? 12 : 28, (i) => '<p>Chapter $number, passage $i. The quick brown fox jumps over the lazy dog. '
            'Frame timing compares consecutive turns on the same book and device.</p>'
            '<img src="illustration.svg" alt="Synthetic illustration $i"/>').join()}
      </body></html>
    ''';
    final file = fixture(
      dir,
      resources: {
        for (final (index, name) in [(1, 'one'), (2, 'two')])
          'OPS/$name.xhtml': utf8.encode(chapter(index)),
        'OPS/illustration.svg': utf8.encode('''
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="260">
          <rect width="320" height="260" fill="#546800"/>
          <circle cx="150" cy="110" r="90" fill="#ffb030"/>
        </svg>
      '''),
      },
    );
    final report = <Json>[];
    final publicationDigest = sha256
        .convert(await file.readAsBytes())
        .toString();
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    try {
      for (final isBaseline in [true, false, false, true]) {
        EpubHost.benchmarkReaderScript = isBaseline
            ? baseline.buffer.asUint8List(
                baseline.offsetInBytes,
                baseline.lengthInBytes,
              )
            : null;
        final store = LocalStore(sqlite3.openInMemory());
        const profile = ServerProfile(
          id: 'android-benchmark',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        );
        store.setSetting('epubDefault', {
          'flow': 'paged',
          'transition': 'curl',
          'columns': 1,
        });
        final repository = Repository(
          profile: profile,
          directory: dir,
          store: store,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: profile.authentication,
            credential: '',
          ),
        )..setOffline(true);
        final key = GlobalKey();
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderDisplay(
                child: BrowserEpubReader(
                  key: key,
                  file: file,
                  repository: repository,
                  book: Book({
                    'id': 'frame-times',
                    'name': 'Fixture',
                    'media': {'mediaProfile': 'EPUB'},
                  }),
                ),
              ),
            ),
          );
          final loading = find.byType(CircularProgressIndicator);
          InAppWebViewController? controller;
          for (var check = 0; check < 200; check++) {
            await tester.pump();
            final dynamic state = key.currentState;
            if (state != null && loading.evaluate().isEmpty) {
              controller = state.browserController as InAppWebViewController?;
              if (controller != null) break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 75));
          }
          expect(controller, isNotNull);
          final response = await controller!
              .callAsyncJavaScript(
                functionBody: '''
            await reader.seek({href:'one.xhtml',progression:.85});
            const initial=reader.position().start.cfi;
            const frameTimes=[], turnTimes=[], positions=new Set();
            const chapters=new Set([reader.position().start.index]);
            let running=true, previous;
            function sample(now) {
              if (!running) return;
              if (previous!=null) frameTimes.push(now-previous);
              previous=now; requestAnimationFrame(sample);
            }
            const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
            await reader.whenIdle();
            await delay(350);
            requestAnimationFrame(sample);
            for(const delta of [1,1,1,-1,1,1,-1,-1,1,1,1,1]) {
              const start=performance.now();
              await reader.turn({delta,style:'curl'});
              turnTimes.push(performance.now()-start);
              positions.add(reader.position().start.cfi);
              chapters.add(reader.position().start.index);
              await delay(65);
            }
            await delay(450);
            running=false;
            const finalPosition=reader.position().start.cfi;
            return JSON.stringify({
              frameTimes, turnTimes, positions:positions.size, chapters:chapters.size,
              moved:initial!==finalPosition, width:innerWidth, height:innerHeight,
              webView:navigator.userAgent, hidden:document.hidden
            });
          ''',
              )
              .timeout(const Duration(seconds: 45));
          expect(response?.error, isNull);
          final data = object(jsonDecode(response!.value as String));
          expect(data['moved'], isTrue);
          expect(data['hidden'], isFalse);
          expect(data['positions'], greaterThan(4));
          expect(data['chapters'], 2);
          expect(data['frameTimes'], isNotEmpty);
          report.add({...data, 'build': isBaseline ? 42 : 43});
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 350));
          repository.dispose();
          store.close();
        }
      }
      binding.reportData ??= <String, dynamic>{};
      binding.reportData!['androidEpubComparison'] = {
        'baseline': '0f9d3f2ecd0b33db34c0b990de05cc37aa9066ee',
        'fixtureSha256': publicationDigest,
        'runs': report,
      };
    } finally {
      EpubHost.benchmarkReaderScript = null;
      binding.framePolicy = policy;
      await dir.delete(recursive: true);
    }
  });
}
