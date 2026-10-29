import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/pdf_preferences.dart';
import 'package:kmreader/features/reader/pdf_reader.dart';
import 'package:kmreader/features/reader/pdf_raster_pages.dart';
import 'package:kmreader/features/reader/pdf_raster_reader.dart';
import 'package:kmreader/features/reader/reader_page.dart';
import 'package:kmreader/features/settings/pdf_reader_settings.dart';
import 'package:kmreader/features/reader/document_readers.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/pdf_fixture.dart';

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 30));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('Native PDF reader did not reach the expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('kmreader-pdf-modes-');
    Pdfrx.cacheDirectoryPath = directory.path;
    final suffix = Platform.isWindows
        ? 'win-x64/pdfium.dll'
        : 'linux-x64/libpdfium.so';
    final module = Directory('.dart_tool/hooks_runner/shared/pdfium_dart/build')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) => file.path.replaceAll('\\', '/').endsWith(suffix));
    Pdfrx.pdfiumModulePath = module.absolute.path;
    await pdfrxInitialize();
  });
  tearDownAll(() => directory.deleteSync(recursive: true));

  test(
    'portable PDF fixture renders mixed-size pages with correct colors',
    () async {
      final document = await PdfDocument.openData(
        rasterPdfFixture(),
        sourceName: 'raster-fixture',
      );
      final source = PdfRasterPages(
        document,
        quality: PdfRasterQuality.compact,
      );
      try {
        expect(source.dimensions.map((p) => p['width']), [300, 450]);
        final codec = await ui.instantiateImageCodec(await source.page(2));
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

  testWidgets('encrypted comic PDF retries without persisting the password', (
    tester,
  ) async {
    final store = LocalStore(sqlite3.openInMemory());
    store.setSetting('useNativePdfReader', false);
    store.setSetting('pdfOfflineRenderQuality', 'compact');
    const profile = ServerProfile(
      id: 'encrypted-raster',
      name: 'Fixture',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.password,
    );
    final repo = Repository(
      profile: profile,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: Authentication.password,
        credential: '',
        client: MockClient((_) async => throw StateError('Unexpected HTTP')),
      ),
      store: store,
      directory: directory,
    )..setOffline(true);
    addTearDown(() {
      repo.dispose();
      store.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentReader(
          load: () async => File('test/fixtures/reader-encrypted.pdf'),
          repository: repo,
          book: Book({
            'id': 'secret',
            'media': {'mediaType': 'application/pdf', 'pagesCount': 5},
          }),
          incognito: true,
        ),
      ),
    );
    await until(tester, () => find.text('PDF Password').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), 'incorrect');
    await tester.tap(find.text('Open'));
    await until(
      tester,
      () => find.text('Incorrect password. Try again.').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), 'fixture-only');
    await tester.tap(find.text('Open'));
    await until(
      tester,
      () =>
          find.byType(ReaderPage).evaluate().isNotEmpty &&
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
    );
    expect(find.text('1 / 5'), findsOneWidget);
    expect(repo.pendingCount, 0);
    expect(
      store.db.select('SELECT value FROM cache').toString(),
      isNot(contains('fixture-only')),
    );
    expect(tester.takeException(), isNull);
    final source =
        tester.widget<ReaderPage>(find.byType(ReaderPage)).rasterPages!
            as PdfRasterPages;
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    final closing = source.close().then((_) => closed = true);
    await until(tester, () => closed);
    await closing;
    await tester.pump(const Duration(milliseconds: 400));
  });

  test(
    'local PDF raster pages coalesce, honor quality and release on close',
    () async {
      final document = await PdfDocument.openFile(
        'test/fixtures/reader-modes.pdf',
      );
      final source = PdfRasterPages(
        document,
        quality: PdfRasterQuality.compact,
      );
      try {
        expect(source.dimensions, hasLength(5));
        expect(PdfRasterQuality.parse('invalid'), PdfRasterQuality.balanced);
        final results = await Future.wait([source.page(1), source.page(1)]);
        expect(identical(results[0], results[1]), true);
        final codec = await ui.instantiateImageCodec(results.first);
        final image = (await codec.getNextFrame()).image;
        expect(image.height, 2048);
        expect(
          image.width,
          (document.pages.first.width / document.pages.first.height * 2048)
              .floor(),
        );
        image.dispose();
        codec.dispose();
        expect(identical(await source.page(1), results.first), true);
        expect(
          identical(await source.page(1, refresh: true), results.first),
          false,
        );
        await expectLater(source.page(0), throwsRangeError);
        final pending = source.page(5);
        final stopped = source.close();
        await expectLater(pending, throwsStateError);
        await stopped;
        await expectLater(source.page(1), throwsStateError);
      } finally {
        await source.close();
      }
    },
  );

  for (final incognito in [false, true]) {
    testWidgets(
      'PDF comic mode reads local pages and preserves continuation; incognito=$incognito',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = LocalStore(sqlite3.openInMemory());
        store.setSetting('useNativePdfReader', false);
        store.setSetting('pdfOfflineRenderQuality', 'compact');
        store.setSetting(
          'readerDefault',
          const ReaderPreferences(animate: false).toJson(),
        );
        const profile = ServerProfile(
          id: 'raster',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.password,
        );
        var requests = 0, nextCalls = 0;
        final nextGate = Completer<void>();
        final repo = Repository(
          profile: profile,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: Authentication.password,
            credential: '',
            client: MockClient((_) async {
              requests++;
              return http.Response('{}', 500);
            }),
          ),
          store: store,
          directory: directory,
        )..setOffline(true);
        addTearDown(() {
          repo.dispose();
          store.close();
        });
        final book = Book({
          'id': 'raster',
          'name': 'Local comic PDF',
          'media': {'mediaType': 'application/pdf', 'pagesCount': 5},
          'readProgress': {'page': 3},
        });
        await tester.pumpWidget(
          MaterialApp(
            home: DocumentReader(
              load: () async => File('test/fixtures/reader-modes.pdf'),
              repository: repo,
              book: book,
              incognito: incognito,
              onNextBook: () {
                nextCalls++;
                return nextGate.future;
              },
            ),
          ),
        );
        await until(
          tester,
          () =>
              find.byType(ReaderPage).evaluate().isNotEmpty &&
              tester
                  .widgetList<RawImage>(find.byType(RawImage))
                  .any((image) => image.image != null),
        );
        expect(find.byType(PdfRasterReader), findsOneWidget);
        expect(find.byType(PdfViewer), findsNothing);
        expect(find.text('3 / 5'), findsOneWidget);
        expect(repo.pendingCount, 0);
        tester.widget<Slider>(find.byType(Slider)).onChanged!(5);
        await until(
          tester,
          () =>
              find.text('5 / 5').evaluate().isNotEmpty &&
              (incognito || repo.pendingCount == 1),
        );
        await tester.tap(find.text('Next Book'));
        await tester.pump();
        await tester.tap(find.text('Next Book'));
        await tester.pump();
        expect(nextCalls, 1);
        nextGate.complete();
        final source =
            tester.widget<ReaderPage>(find.byType(ReaderPage)).rasterPages!
                as PdfRasterPages;
        await until(
          tester,
          () =>
              !source.isRendering &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
        expect(repo.pendingCount, incognito ? 0 : 1);
        if (!incognito) {
          expect(store.progress(profile.id, book.id)?['completed'], true);
        }
        expect(requests, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
      },
    );
  }

  for (final width in [320.0, 1280.0]) {
    testWidgets('PDF engine and quality preferences fit $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = LocalStore(sqlite3.openInMemory());
      addTearDown(store.close);
      await tester.pumpWidget(
        MaterialApp(home: PdfReaderSettingsPage(store: store)),
      );
      expect(find.text('Balanced (3072 px)'), findsNothing);
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Use Native PDF Reader'),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('preference::pdfOfflineRenderQuality')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(CheckedPopupMenuItem<Object>, 'Ultra (5120 px)'),
      );
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<Object>, 'Ultra (5120 px)'),
      );
      await tester.pumpAndSettle();
      expect(store.setting<bool>('useNativePdfReader'), false);
      expect(store.setting<String>('pdfOfflineRenderQuality'), 'ultra');
      expect(tester.takeException(), isNull);
    });
  }

  test('PDF layout preserves canonical order, cover and complete mixed-size spreads', () {
    const sizes = [
      Size(300, 450),
      Size(450, 300),
      Size(300, 450),
      Size(300, 450),
      Size(450, 300),
    ];
    final ltr = PdfReaderLayout(
      sizes: sizes,
      preferences: const PdfPreferences(),
      viewport: const Size(1200, 800),
    );
    expect(ltr.slots[0], isNot(ltr.slots[1]));
    expect(ltr.slots[1], ltr.slots[2]);
    expect(ltr.slots[3], ltr.slots[4]);
    expect(ltr.pages[1].left, lessThan(ltr.pages[2].left));
    expect(ltr.nearestPage(ltr.slots[3], preferred: 4), 4);
    expect(ltr.nearestPage(ltr.slots[3], preferred: 5), 5);
    expect(ltr.nearestPage(ltr.pages[4].deflate(10), preferred: 4), 5);
    final rtl = PdfReaderLayout(
      sizes: sizes,
      preferences: const PdfPreferences(rtl: true),
      viewport: const Size(1200, 800),
    );
    expect(rtl.pages[1].left, greaterThan(rtl.pages[2].left));
    expect(rtl.pages[0].center.dx, closeTo(rtl.documentSize.width / 2, .001));
    for (var i = 0; i < sizes.length; i++) {
      expect(rtl.pages[i].size, sizes[i]);
      expect(rtl.slots[i].contains(rtl.pages[i].center), isTrue);
    }
    final paged = PdfReaderLayout(
      sizes: sizes,
      preferences: const PdfPreferences(rtl: true),
      viewport: const Size(400, 800),
    );
    expect(paged.pages[0].left, greaterThan(paged.pages[1].left));
    expect(paged.nearestPage(paged.slots[3]), 4);
    final continuous = PdfReaderLayout(
      sizes: sizes,
      preferences: const PdfPreferences(
        presentation: PdfPresentation.singleContinuous,
      ),
      viewport: const Size(1200, 800),
    );
    expect(continuous.pages[1].top, greaterThan(continuous.pages[0].bottom));
    expect(
      PdfPreferences.fromJson({'presentation': 'invalid'}).presentation,
      PdfPresentation.auto,
    );
    expect(
      PdfPreferences.fromJson(const PdfPreferences(rtl: true).toJson()).rtl,
      isTrue,
    );
    expect(
      const PdfPreferences().forSeries({
        'readingDirection': 'WEBTOON',
      }).vertical,
      isTrue,
    );
    expect(
      const PdfPreferences(useSeriesDirection: false)
          .forSeries({'readingDirection': 'RIGHT_TO_LEFT'})
          .rtl,
      isFalse,
    );
  });

  for (final incognito in [false, true]) {
    testWidgets(
      'native PDF layout/theme changes keep position and do not write progress; incognito=$incognito',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = LocalStore(sqlite3.openInMemory());
        const profile = ServerProfile(
          id: 'pdf',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.password,
        );
        var requests = 0;
        final repo = Repository(
          profile: profile,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: Authentication.password,
            credential: '',
            client: MockClient((_) async {
              requests++;
              return http.Response('{}', 500);
            }),
          ),
          store: store,
          directory: directory,
        )..setOffline(true);
        final book = Book({
          'id': 'pdf',
          'seriesId': 's',
          'name': 'Reader fixture',
          'media': {'mediaType': 'application/pdf', 'pagesCount': 5},
          'readProgress': {'page': 3},
        });
        var nextCalls = 0;
        final nextGate = Completer<void>();
        store.cache(profile.id, 'detail:series:s', {
          'metadata': {'readingDirection': 'RIGHT_TO_LEFT'},
        });
        addTearDown(() {
          repo.dispose();
          store.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: DocumentReader(
              load: () async => File('test/fixtures/reader-modes.pdf'),
              repository: repo,
              book: book,
              incognito: incognito,
              onNextBook: () {
                nextCalls++;
                return nextGate.future;
              },
            ),
          ),
        );
        await until(tester, () => find.text('3 / 5').evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        expect(repo.pendingCount, 0);
        final native = tester.widget<PdfViewer>(find.byType(PdfViewer));
        final visible = native.controller!.visibleRect.inflate(.1);
        for (final index in [1, 2]) {
          final rect = native.controller!.layout.pageLayouts[index];
          expect(
            visible.contains(rect.topLeft),
            isTrue,
            reason: 'Both pages of the spread must fit, including after resume',
          );
          expect(visible.contains(rect.bottomRight), isTrue);
        }
        expect(
          native.controller!.layout.pageLayouts[1].left,
          greaterThan(native.controller!.layout.pageLayouts[2].left),
          reason: 'Cached series RTL must apply before offline rendering',
        );
        await tester.tap(find.byTooltip('PDF Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Single Page Continuous'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sepia'));
        await tester.pumpAndSettle();
        expect(
          object(store.cached(profile.id, 'pdf:pdf'))['presentation'],
          'single-continuous',
        );
        expect(
          repo.pendingCount,
          0,
          reason: 'Changing layout/theme must preserve progress',
        );
        await tester.tapAt(const Offset(20, 100));
        await tester.pumpAndSettle();
        expect(find.text('3 / 5'), findsOneWidget);
        await tester.tap(find.byTooltip('Next Page'));
        await tester.pumpAndSettle();
        expect(find.text('4 / 5'), findsOneWidget);
        expect(repo.pendingCount, incognito ? 0 : 1);
        if (!incognito) expect(store.progress(profile.id, book.id)?['page'], 4);
        await tester.tap(find.byTooltip('Next Page'));
        await tester.pumpAndSettle();
        expect(find.text('5 / 5'), findsOneWidget);
        await tester.tap(find.byTooltip('Next Book'));
        await tester.pump();
        expect(nextCalls, 1);
        await tester.tap(find.byTooltip('Next Book'));
        await tester.pump();
        expect(nextCalls, 1);
        nextGate.complete();
        await tester.pumpAndSettle();
        expect(repo.pendingCount, incognito ? 0 : 1);
        if (!incognito) {
          expect(store.progress(profile.id, book.id)?['completed'], true);
        }
        expect(requests, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'encrypted PDF retries a wrong password and never persists credentials',
    (tester) async {
      final store = LocalStore(sqlite3.openInMemory());
      const profile = ServerProfile(
        id: 'password',
        name: 'Fixture',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.password,
      );
      final repo = Repository(
        profile: profile,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: Authentication.password,
          credential: '',
          client: MockClient((_) async => throw StateError('Unexpected HTTP')),
        ),
        store: store,
        directory: directory,
      )..setOffline(true);
      addTearDown(() {
        repo.dispose();
        store.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PdfReader(
            file: File('test/fixtures/reader-encrypted.pdf'),
            repository: repo,
            book: Book({
              'id': 'secret',
              'media': {'pagesCount': 5},
            }),
            incognito: true,
          ),
        ),
      );
      await until(
        tester,
        () => find.text('PDF Password').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'incorrect');
      await tester.tap(find.text('Open'));
      await until(
        tester,
        () => find.text('Incorrect password. Try again.').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'fixture-only');
      await tester.tap(find.text('Open'));
      await until(tester, () => find.text('1 / 5').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'page 4');
      await until(tester, () => find.text('1/1').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('4 / 5'), findsOneWidget);
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(
        find.text('1/1'),
        findsOneWidget,
        reason: 'Search results survive a viewport/keyboard size change',
      );
      expect(find.text('4 / 5'), findsOneWidget);
      expect(repo.pendingCount, 0);
      expect(
        store.db.select('SELECT value FROM cache').toString(),
        isNot(contains('fixture-only')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
