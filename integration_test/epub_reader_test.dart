import 'package:kmreader/core/background_downloads.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:kmreader/features/reader/reader_ocr.dart';
import 'package:kmreader/features/reader/bubble_detector.dart';
import 'package:kmreader/features/reader/page_upscaler.dart';
import 'package:kmreader/features/reader/pdf_raster_pages.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_reader.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/ui/theme.dart';
import 'package:sqlite3/sqlite3.dart';

import '../test/support/epub_fixture.dart';
import '../test/support/pdf_fixture.dart';
import 'support/background_download_check.dart';
import 'support/scroll_checks.dart';
import 'support/windows_wheel_check.dart';
import 'support/epub_performance_check.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  verifyNativeBackgroundDownloads();
  verifyNativeScrolling(binding);
  verifyNativeWindowsWheel();
  verifyNativeEpubPerformance();
  testWidgets('Android export rejects files outside app-private storage', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;
    for (final method in ['exportLog', 'exportImage']) {
      await expectLater(
        const MethodChannel('dev.levalue.kmreader/export')
            .invokeMethod<bool>(method, {'path': '/system/build.prop'}),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'export_failed',
          ),
        ),
      );
    }
  });
  testWidgets('native display-awake request releases its OS ownership', (
    tester,
  ) async {
    try {
      await ReaderDisplay.channel.invokeMethod<void>('setKeepAwake', true);
      expect(
        await ReaderDisplay.channel.invokeMethod<bool>('getKeepAwake'),
        true,
      );
    } finally {
      await ReaderDisplay.channel.invokeMethod<void>('setKeepAwake', false);
    }
    expect(
      await ReaderDisplay.channel.invokeMethod<bool>('getKeepAwake'),
      false,
    );
  });
  testWidgets(
    'native app icon options update the actual launcher or window icon',
    (tester) async {
      const icons = MethodChannel('dev.levalue.kmreader/privacy');
      try {
        for (final name in ['classic', 'legacy', 'default']) {
          await icons.invokeMethod<void>('setAppIcon', name);
          if (Platform.isAndroid) {
            expect(await icons.invokeListMethod<String>('getAppIcons'), [name]);
          } else if (Platform.isWindows) {
            final state = await icons.invokeMapMethod<String, dynamic>(
              'getAppIcon',
            );
            expect(state?['name'], name);
            expect(state?['valid'], true);
          }
        }
      } finally {
        await icons.invokeMethod<void>('setAppIcon', 'default');
      }
    },
  );
  testWidgets(
    'native fullscreen and status-bar options restore their window state',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Window preference verification')),
        ),
      );
      if (Platform.isWindows) {
        try {
          await ReaderDisplay.channel.invokeMethod<void>('setFullscreen', true);
          expect(
            await ReaderDisplay.channel.invokeMethod<bool>('getFullscreen'),
            true,
          );
        } finally {
          await ReaderDisplay.channel.invokeMethod<void>(
            'setFullscreen',
            false,
          );
        }
        expect(
          await ReaderDisplay.channel.invokeMethod<bool>('getFullscreen'),
          false,
        );
      } else if (Platform.isAndroid) {
        try {
          await ReaderDisplay.channel.invokeMethod<Object?>(
            'setReaderMode',
            true,
          );
          for (final wanted in [true, false]) {
            await ReaderDisplay.channel.invokeMethod<void>(
              'setReaderStatusBarVisible',
              wanted,
            );
            bool? visible;
            for (var i = 0; i < 20; i++) {
              visible = await ReaderDisplay.channel.invokeMethod<bool>(
                'getReaderStatusBarVisible',
              );
              if (visible == wanted) break;
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(visible, wanted);
          }
        } finally {
          await ReaderDisplay.channel.invokeMethod<void>(
            'setReaderStatusBarVisible',
            false,
          );
          await ReaderDisplay.channel.invokeMethod<Object?>(
            'setReaderMode',
            false,
          );
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final layout in ['reflowable', 'fixed', 'vertical']) {
    testWidgets(
      'native $layout WebView paginates and preserves saved CFI through settings',
      (tester) async {
        await Strings.initialize();
        final directory = await Directory.systemTemp.createTemp(
          'kmreader-native-epub-',
        );
        final store = LocalStore(sqlite3.openInMemory());
        if (layout == 'reflowable') {
          store.setSetting('epubDefault', {'advancedLayout': false});
        }
        const profile = ServerProfile(
          id: 'native-epub',
          name: 'Native fixture',
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
          'id': 'native-book',
          'name': 'EPUB native verification',
          'media': {'mediaProfile': 'EPUB', 'pagesCount': 100},
        });
        final file = switch (layout) {
          'fixed' => fixedLayoutFixture(directory),
          'vertical' => verticalEpubFixture(directory),
          _ => fixture(directory),
        };
        Future<void> waitFor(bool Function() ready) async {
          for (var i = 0; i < 180; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            if (ready()) return;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final labels = find
              .byType(Text)
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .whereType<String>()
              .join(' | ');
          fail('Native EPUB did not reach its expected state. UI: $labels');
        }

        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(Brightness.light),
              home: ReaderDisplay(
                child: BrowserEpubReader(
                  file: file,
                  repository: repository,
                  book: book,
                ),
              ),
            ),
          );
          await waitFor(
            () =>
                find.byType(CircularProgressIndicator).evaluate().isEmpty &&
                find.byTooltip('Next Page').evaluate().isNotEmpty,
          );
          expect(find.textContaining('Install Microsoft Edge'), findsNothing);
          await tester.tap(find.byTooltip('Next Page'));
          await waitFor(
            () =>
                text(object(store.cached(profile.id, 'epub:${book.id}'))['cfi'])
                    .startsWith('epubcfi('),
          );
          final saved = object(store.cached(profile.id, 'epub:${book.id}'));
          expect(repository.pendingCount, 1);
          await tester.tap(find.byType(PopupMenuButton<String>).first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Text Settings').last);
          await tester.pumpAndSettle();
          if (layout == 'fixed') {
            expect(
              find.text('This book uses a fixed page layout.'),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('epub-fontSize')), findsNothing);
          } else {
            final slider = find.byType(Slider).first;
            await tester.drag(slider, const Offset(80, 0));
            await tester.pumpAndSettle();
            await Future<void>.delayed(const Duration(seconds: 1));
            await tester.pump();
            expect(
              object(store.cached(profile.id, 'epub:${book.id}'))['cfi'],
              saved['cfi'],
            );
            expect(
              object(store.cached(profile.id, 'epub:${book.id}'))['fontSize'],
              isNot(19),
            );
            expect(
              object(
                store.cached(profile.id, 'epub:${book.id}'),
              )['advancedLayout'],
              isTrue,
              reason: 'An explicit typography adjustment must override publisher typography',
            );
          }
          for (final flow
              in layout == 'reflowable' ? ['Vertical', 'Paged'] : <String>[]) {
            await tester.tap(
              find.text(flow == 'Vertical' ? 'Paged' : 'Vertical').last,
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text(flow).last);
            await tester.pumpAndSettle();
            await Future<void>.delayed(const Duration(seconds: 1));
            await tester.pump();
            expect(
              object(store.cached(profile.id, 'epub:${book.id}'))['flow'],
              flow == 'Vertical' ? 'scrolled' : 'paged',
            );
            expect(
              object(store.cached(profile.id, 'epub:${book.id}'))['cfi'],
              saved['cfi'],
            );
          }
          await tester.tap(find.byTooltip('Close').last);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byTooltip(layout == 'fixed' ? 'Previous Page' : 'Next Page'),
          );
          await waitFor(
            () =>
                object(store.cached(profile.id, 'epub:${book.id}'))['cfi'] !=
                saved['cfi'],
          );
          if (Platform.isAndroid) {
            debugPrint('Native EPUB PixelCopy capture started');
            final bytes = await ReaderDisplay.channel
                .invokeMethod<Uint8List>('captureScreenshot')
                .timeout(const Duration(seconds: 10));
            expect(bytes, isNotEmpty);
            binding.reportData ??= <String, dynamic>{};
            binding.reportData!['screenshots'] ??= <dynamic>[];
            (binding.reportData!['screenshots'] as List).add({
              'screenshotName': 'epub-native-$layout',
              'bytes': bytes!,
            });
            debugPrint('Native EPUB PixelCopy capture completed');
          }
        } finally {
          await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
          await Future<void>.delayed(const Duration(seconds: 1));
          await tester.pump();
          expect(tester.takeException(), isNull);
          repository.dispose();
          store.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
  testWidgets('native EPUB text settings accept global typography extremes', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'kmreader-native-typography-',
    );
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'native-typography',
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
    store.setSetting('epubDefault', {
      'advancedLayout': true,
      'fontSize': 76.0,
      'lineHeight': .5,
      'letterSpacing': 1.0,
    });
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: ReaderDisplay(
            child: BrowserEpubReader(
              repository: repository,
              book: Book({
                'id': 'extremes',
                'media': {'mediaProfile': 'EPUB'},
              }),
              file: fixture(directory),
              incognito: true,
            ),
          ),
        ),
      );
      for (var i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byTooltip('Next Page').evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(find.byTooltip('Next Page'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text Settings').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widgetList<Slider>(find.byType(Slider)).map((s) => s.value),
        containsAll([76.0, .5, 1.0]),
      );
      expect(repository.pendingCount, 0);
    } finally {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await repository.stopDownloadWork();
      store.close();
      await directory.delete(recursive: true);
    }
  });
  testWidgets(
    'native on-device OCR recognizes a rendered image without retaining private text',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'kmreader-native-ocr-',
      );
      try {
        final reader = ReaderOcr(directory);
        final languages = await reader.languages();
        if (languages.isEmpty) {
          markTestSkipped(
            'No OCR language pack is installed on this Windows runner.',
          );
          return;
        }
        final recorder = ui.PictureRecorder();
        final paintCanvas = Canvas(recorder);
        paintCanvas.drawColor(Colors.white, BlendMode.src);
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 72))
          ..pushStyle(ui.TextStyle(color: Colors.black, fontSize: 72))
          ..addText('HELLO READER');
        final paragraph = builder.build()
          ..layout(const ui.ParagraphConstraints(width: 760));
        paintCanvas.drawParagraph(paragraph, const Offset(20, 60));
        final picture = recorder.endRecording(),
            image = await picture.toImage(800, 240);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final recognized = await reader.recognize(
          bytes!.buffer.asUint8List(),
          languages.contains('latin')
              ? 'latin'
              : languages.contains('en-US')
              ? 'en-US'
              : languages.first,
          cache: false,
        );
        expect(
          recognized.text.toUpperCase(),
          allOf(contains('HELLO'), contains('READER')),
        );
        expect(recognized.blocks, isNotEmpty);
        expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
        image.dispose();
        picture.dispose();
        paragraph.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets('native bubble detection matches the converted model probe', (
    tester,
  ) async {
    final detector = BubbleDetector();
    try {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(16, 16);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final result = await detector.detect(
        data!.buffer.asUint8List(),
        cache: false,
      );
      expect(result.boxes, isEmpty);
      expect(result.maxScore, closeTo(8.584473835e-5, 2e-5));
    } finally {
      await detector.close();
    }
  });
  testWidgets(
    'native PDFium renders offline comic pages with the chosen quality',
    (tester) async {
      await pdfrxFlutterInitialize();
      final document = await PdfDocument.openData(
        rasterPdfFixture(),
        sourceName: 'native-pdf-raster',
      );
      final source = PdfRasterPages(
        document,
        quality: PdfRasterQuality.compact,
      );
      try {
        expect(source.dimensions, hasLength(2));
        final bytes = await source.page(2);
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        try {
          expect(image.width, 2048);
          expect(image.height, 1365);
          final pixels = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final center =
              (image.height ~/ 2 * image.width + image.width ~/ 2) * 4;
          expect(pixels!.buffer.asUint8List().sublist(center, center + 4), [
            0,
            0,
            255,
            255,
          ]);
        } finally {
          image.dispose();
          codec.dispose();
        }
      } finally {
        await source.close();
      }
    },
  );
  testWidgets('native portable Waifu2x produces a cached 2x image', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'kmreader-native-upscale-',
    );
    final upscaler = PageUpscaler(directory);
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 11, 24),
        Paint()..color = Colors.red,
      );
      final picture = recorder.endRecording(),
          image = await picture.toImage(22, 24);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final output = await upscaler.enhance(
        data!.buffer.asUint8List(),
        const Size(100, 100),
      );
      expect(output, isNotNull, reason: upscaler.error);
      final codec = await ui.instantiateImageCodec(output!);
      final result = (await codec.getNextFrame()).image;
      expect(result.width, 44);
      expect(result.height, 48);
      result.dispose();
      codec.dispose();
    } finally {
      upscaler.close();
      await Future<void>.delayed(const Duration(seconds: 1));
      await directory.delete(recursive: true);
    }
  });
}

@pragma('vm:entry-point')
Future<void> backgroundDownloadMain(List<String> arguments) =>
    runWindowsDownloadWorker(arguments);
