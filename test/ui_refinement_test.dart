import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/next_book.dart';
import 'package:kmreader/core/reader_defaults.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/dashboard.dart';
import 'package:kmreader/features/catalog/detail_page.dart';
import 'package:kmreader/features/catalog/reading_stats_overview.dart';
import 'package:kmreader/features/offline/downloads_page.dart';
import 'package:kmreader/features/reader/epub_session.dart';
import 'package:kmreader/features/reader/pdf_preferences.dart';
import 'package:kmreader/features/reader/reading_session.dart';
import 'package:kmreader/features/settings/reader_settings.dart';
import 'package:kmreader/features/settings/service_settings.dart';
import 'package:kmreader/features/settings/settings_style.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/ui/theme.dart';
import 'package:kmreader/ui/section_scroll_view.dart';
import 'package:kmreader/ui/reader_chrome.dart';
import 'package:kmreader/ui/shell_navigation.dart';

import 'widget_test.dart' show FixtureRepository, screenshot;
import 'epub_navigation_test.dart' show createBook;

const account = ServerProfile(
  id: 'ui',
  name: 'UI fixture',
  url: 'https://example.invalid',
  email: '',
  authentication: Authentication.apiKey,
);
Book book(
  String id,
  int number, {
  bool read = false,
  String series = 's',
  String library = 'one',
}) => Book({
  'id': id,
  'seriesId': series,
  'libraryId': library,
  'name': 'Book $id',
  'metadata': {'numberSort': number, 'title': 'Book $id'},
  'media': {'pagesCount': 10},
  if (read) 'readProgress': {'completed': true, 'page': 10},
});

class DashboardFixture extends FixtureRepository {
  DashboardFixture({
    required super.profile,
    required super.store,
    required super.directory,
    required super.api,
  });
  int catalogs = 0;
  @override
  Future<CatalogPage> catalog(
    String kind, {
    int page = 0,
    String? search,
    String sort = 'metadata.titleSort,asc',
    Json? condition,
    String? path,
    bool force = false,
    int size = 40,
    String? libraryId,
    List<String>? libraryIds,
  }) async {
    catalogs++;
    return CatalogPage(
      [
        for (var i = 0; i < 4; i++)
          CatalogItem(
            kind,
            kind == 'books'
                ? book('b$i', i).json
                : {
                    'id': 's$i',
                    'metadata': {'title': 'Series $i'},
                    'booksCount': 4,
                  },
          ),
      ],
      true,
      4,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await Strings.initialize();
    for (final font in jsonDecode(
      await rootBundle.loadString('FontManifest.json'),
    ) as List) {
      final loader = FontLoader(font['family'] as String);
      for (final item in font['fonts'] as List) {
        loader.addFont(rootBundle.load(item['asset'] as String));
      }
      await loader.load();
    }
    var directory = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 9; i++) {
      final file = File(
        '${directory.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      );
      if (file.existsSync()) {
        await (FontLoader('Segoe UI')..addFont(
              Future.value(ByteData.sublistView(file.readAsBytesSync())),
            ))
            .load();
        break;
      }
      directory = directory.parent;
    }
  });
  late LocalStore store;
  late Directory directory;
  final repositories = <Repository>[];
  setUp(() {
    store = LocalStore(sqlite3.openInMemory());
    directory = Directory.systemTemp.createTempSync('kmreader-ui-');
  });
  tearDown(() async {
    for (final repo in repositories) {
      repo.dispose();
      await repo.stopDownloadWork();
    }
    repositories.clear();
    store.close();
    directory.deleteSync(recursive: true);
  });
  Repository repository({http.Client? client}) {
    store.saveServer(account);
    final value = Repository(
      profile: account,
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse(account.url),
        authentication: Authentication.apiKey,
        credential: 'fixture',
        client: client ?? MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    repositories.add(value);
    return value;
  }

  test('localized page templates retain named values and distinguish Chinese scripts', () {
    expect(Strings.preferredLocale('zh_HK')?.scriptCode, 'Hant');
    expect(Strings.preferredLocale('zh-Hans-SG')?.scriptCode, 'Hans');
    expect(
      Strings(const Locale('it'))('Page {page} of {total}', {
        'page': 4,
        'total': 38,
      }),
      'Pagina 4 di 38',
    );
  });

  testWidgets(
    'compact large-text navigation retains all accessible destinations',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(semantics.dispose);
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            bottomNavigationBar: ShellNavigationBar(
              selectedIndex: 0,
              labels: const [
                'Dashboard',
                'Library',
                'Lists',
                'Local books',
                'Settings',
              ],
              icons: const [
                Icons.home,
                Icons.book,
                Icons.list,
                Icons.folder,
                Icons.settings,
              ],
              onSelected: (_) {},
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel(RegExp('Settings')), findsAny);
      expect(find.bySemanticsLabel(RegExp('Local books')), findsAny);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior,
        NavigationDestinationLabelBehavior.onlyShowSelected,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a reader control retains keyboard focus and formats its page label',
    (tester) async {
      final selected = FocusNode();
      addTearDown(selected.dispose);
      var activated = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ReaderCapsule(
                child: TextButton(
                  focusNode: selected,
                  onPressed: () => activated = true,
                  child: Text(readingPageLabel(context, 12, 69)),
                ),
              ),
            ),
          ),
        ),
      );
      selected.requestFocus();
      await tester.pump();
      expect(readerControlHasFocus(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(activated, isTrue);
      expect(find.text('Page 12 of 69'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  test('global reader updates override only changed book fields and preserve locators/progress', () {
    store.cache(account.id, 'epub:b', {
      'fontSize': 22.0,
      'lineHeight': 1.9,
      'chapter': 3,
      'cfi': 'epubcfi(saved)',
      'progress': .4,
    });
    store.cache('other', 'epub:b', {'fontSize': 23.0, 'cfi': 'epubcfi(other)'});
    store.cache(account.id, 'reader:b', {'background': 'black', 'rotation': 1});
    updateReaderDefaults(store, 'epubDefault', {'fontSize': 30.0});
    final saved = object(store.cached(account.id, 'epub:b'));
    expect(saved.containsKey('fontSize'), false);
    expect(saved['cfi'], 'epubcfi(saved)');
    expect(saved['lineHeight'], 1.9);
    expect(saved['chapter'], 3);
    expect(
      object(store.cached('other', 'epub:b')).containsKey('fontSize'),
      false,
    );
    expect(object(store.cached(account.id, 'reader:b'))['rotation'], 1);
    expect(object(store.setting<dynamic>('epubDefault'))['fontSize'], 30.0);
  });

  test(
    'an already open EPUB keeps a new global font size after saving progress',
    () async {
      final repo = repository();
      final volume = book('epub', 1);
      final file = createBook(directory);
      store.cache(account.id, 'epub:epub', {
        'fontSize': 23.0,
        'lineHeight': 1.9,
      });
      final session = await EpubSession.open(repo, volume, file);
      try {
        expect(session.preferences.fontSize, 23);
        updateReaderDefaults(store, 'epubDefault', {
          'fontSize': 29.0,
          'flow': 'paged',
        });
        session.receive({
          'type': 'position',
          'href': session.href,
          'progression': .4,
          'cfi': 'epubcfi(saved)',
          'page': 5,
          'changed': true,
        });
        session.save();
        final saved = object(store.cached(account.id, 'epub:epub'));
        expect(saved, isNot(contains('fontSize')));
        expect(saved['lineHeight'], 1.9);
        expect(saved['cfi'], 'epubcfi(saved)');
        expect(session.resetPreferences().fontSize, 29);
        final reset = object(store.cached(account.id, 'epub:epub'));
        expect(reset, isNot(contains('lineHeight')));
        expect(reset['cfi'], 'epubcfi(saved)');
      } finally {
        await session.close();
      }
    },
  );

  test('raster PDF defaults keep comic settings separate and pair continuous pages', () {
    store.cache(account.id, 'pdf-raster:pdf', {
      'direction': 'rtl',
      'background': 'black',
      'rotation': 1,
    });
    store.cache(account.id, 'reader:comic', {
      'direction': 'rtl',
      'background': 'black',
    });
    updateReaderDefaults(store, 'pdfDefault', {'background': 'white'});
    final raster = object(store.cached(account.id, 'pdf-raster:pdf'));
    expect(raster, {'direction': 'rtl', 'rotation': 1});
    expect(
      object(store.cached(account.id, 'reader:comic'))['background'],
      'black',
    );
    final session = ReadingSession(
      count: 6,
      initialPage: 3,
      continuousSpreads: true,
      preferences: const ReaderPreferences(
        mode: ReadingMode.vertical,
        spread: true,
        soloCover: true,
      ),
      onCommit: (_) {},
    );
    addTearDown(session.dispose);
    expect(session.itemCount, 4);
    expect(session.itemIndex, 1);
    expect(session.firstPage(1), 2);
    session.next();
    expect(session.page, 4);
  });

  for (final size in [const Size(320, 520), const Size(1160, 520)]) {
    testWidgets('series detail keeps its catalog usable at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = DashboardFixture(
        profile: account,
        store: store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(account.url),
          authentication: Authentication.apiKey,
          credential: 'fixture',
        ),
      );
      repositories.add(repo);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(
              repository: repo,
              item: CatalogItem('series', {
                'id': 's',
                'name': 'Fixture series',
                'metadata': {'summary': 'Series description'},
              }),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('Fixture series'), findsNWidgets(2));
        final contents = find.byType(CustomScrollView);
        expect(contents, findsOneWidget);
        if (size.width > 880) {
          expect(find.text('Series description'), findsOneWidget);
          expect(tester.getTopLeft(contents).dx, greaterThan(290));
        } else {
          await tester.drag(contents, const Offset(0, -190));
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.text('Book b2'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(repo.stopDownloadWork);
        repositories.remove(repo);
      }
    });
  }

  testWidgets('downloads separate waiting, failed and available books', (
    tester,
  ) async {
    final repo = DashboardFixture(
      profile: account,
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse(account.url),
        authentication: Authentication.apiKey,
        credential: 'fixture',
      ),
    );
    repositories.add(repo);
    await tester.binding.setSurfaceSize(const Size(320, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    store.saveDownload(account.id, book('waiting', 1), 'paused');
    store.saveDownload(account.id, book('failed', 2), 'failed');
    store.saveDownload(account.id, book('ready', 3), 'ready', size: 2097152);
    try {
      await tester.pumpWidget(
        MaterialApp(home: DownloadsPage(repository: repo)),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Download Queue'), findsOneWidget);
      expect(find.text('Interrupted Downloads'), findsOneWidget);
      expect(find.text('Completed Downloads'), findsOneWidget);
      expect(find.text('2.0 MiB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(repo.stopDownloadWork);
      repositories.remove(repo);
    }
  });
  test('new installs use original reader defaults; existing installs preserve choices', () {
    initializeReaderDefaults(store);
    final prefs = object(store.setting<dynamic>('readerDefault'));
    expect(prefs['pageLayout'], 'auto');
    expect(prefs['soloCover'], true);
    expect(prefs['doubleTapZoom'], 2);
    expect(prefs['showProgress'], true);
    expect(object(store.setting<dynamic>('pdfDefault'))['showProgress'], true);
    expect(store.setting<int>('progressRecordingThreshold'), 3);
    expect(
      object(store.setting<dynamic>('epubDefault'))['advancedLayout'],
      false,
    );
    store.close();
    store = LocalStore(sqlite3.openInMemory());
    store.saveServer(account);
    store.setSetting('readerDefault', {
      'pageLayout': 'single',
      'background': 'sepia',
    });
    initializeReaderDefaults(store);
    expect(object(store.setting<dynamic>('readerDefault')), {
      'pageLayout': 'single',
      'background': 'sepia',
    });
    expect(store.setting<int>('progressRecordingThreshold'), isNull);
  });
  test('next-unread fallback works with old servers, ordered lists and offline data', () async {
    var requests = 0;
    final repo = repository(
      client: MockClient((request) async {
        requests++;
        expect(request.url.queryParameters['skipRead'], 'true');
        return http.Response(jsonEncode(book('b', 2, read: true).json), 200);
      }),
    );
    store.cacheBooks(account.id, [
      for (final b in [book('a', 1), book('b', 2, read: true), book('c', 3)])
        CatalogItem('books', b.json),
    ]);
    final resolver = NextBookResolver(repo);
    expect((await resolver.after(book('a', 1)))?.id, 'c');
    expect(requests, 1);
    repo.setOffline(true);
    expect((await resolver.after(book('a', 1)))?.id, 'c');
    expect(requests, 1);
    store.setSetting('suggestNextUnreadBook', false);
    expect((await resolver.after(book('a', 1)))?.id, 'b');
    store.cacheItems(account.id, [
      CatalogItem('readlists', {
        'id': 'list',
        'ordered': true,
        'bookIds': ['c', 'a', 'b'],
      }),
    ]);
    expect((await resolver.after(book('c', 3), readListId: 'list'))?.id, 'a');
    expect((await resolver.after(book('b', 2), readListId: 'list')), isNull);
  });
  test('multi-library scope reaches both search bodies and special endpoint queries', () async {
    final seen = <http.Request>[];
    final repo = repository(
      client: MockClient((request) async {
        seen.add(request);
        return http.Response(
          '{"content":[],"last":true,"totalElements":0}',
          200,
        );
      }),
    );
    await repo.catalog('books', libraryIds: ['two', 'one'], force: true);
    final payload = object(jsonDecode(seen.single.body));
    final conditions = object(payload['condition'])['allOf'] as List;
    expect(object(conditions.single)['anyOf'], [
      {
        'libraryId': {'operator': 'is', 'value': 'one'},
      },
      {
        'libraryId': {'operator': 'is', 'value': 'two'},
      },
    ]);
    await repo.catalog(
      'books',
      path: '/api/v1/books/ondeck',
      libraryIds: ['two', 'one'],
      force: true,
    );
    expect(seen.last.url.queryParametersAll['library_id'], ['one', 'two']);
    store.cacheBooks(account.id, [
      CatalogItem('books', book('one', 1, library: 'one').json),
      CatalogItem('books', book('two', 2, library: 'two').json),
      CatalogItem('books', book('three', 3, library: 'three').json),
    ]);
    repo.setOffline(true);
    final cached = await repo.catalog('books', libraryIds: ['two', 'one']);
    expect(cached.items.map((i) => i.id).toSet(), {'one', 'two'});
  });
  test(
    'PDF vertical page direction keeps canonical pages on a vertical axis',
    () {
      final prefs = PdfPreferences.fromJson({
        'presentation': 'single-paged',
        'vertical': true,
      });
      final layout = PdfReaderLayout(
        sizes: const [Size(300, 450), Size(300, 450)],
        preferences: prefs,
        viewport: const Size(600, 800),
      );
      expect(layout.pages[1].top, greaterThan(layout.pages[0].bottom));
      expect(layout.pages[1].left, layout.pages[0].left);
      expect(
        prefs.forSeries({'readingDirection': 'RIGHT_TO_LEFT'}).vertical,
        false,
      );
      expect(
        prefs.copy(useSeriesDirection: false).forSeries({
          'readingDirection': 'RIGHT_TO_LEFT',
        }).vertical,
        true,
      );
    },
  );
  test('heatmap ranges use calendar months, including leap dates and locale week starts', () {
    expect(
      readingRangeStart('last6Months', DateTime(2026, 8, 31), []),
      DateTime(2026, 2, 28),
    );
    expect(
      readingRangeStart('lastYear', DateTime(2024, 2, 29), []),
      DateTime(2023, 2, 28),
    );
    expect(
      readingRangeStart(
        'thisWeek',
        DateTime(2026, 10, 29),
        [],
        firstWeekday: 1,
      ),
      DateTime(2026, 10, 26),
    );
    expect(
      readingRangeStart('allTime', DateTime(2026, 10, 29), [
        DateTime(2020),
        DateTime(2030),
      ]),
      DateTime(2020),
    );
  });
  testWidgets(
    'Dashboard wheel boundary keeps content stable and never reloads shelves',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = DashboardFixture(
        profile: account,
        store: store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(account.url),
          authentication: Authentication.apiKey,
          credential: 'fixture',
        ),
      );
      repositories.add(repo);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(body: Dashboard(repository: repo)),
        ),
      );
      await tester.runAsync(() async {
        for (final width in [128, 256, 512, 1024]) {
          await precacheImage(
            ResizeImage(MemoryImage(FixtureRepository.bytes), width: width),
            tester.element(find.byType(Dashboard)),
          );
        }
      });
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      final list = find.byKey(const PageStorageKey('dashboard-scroll'));
      await tester.fling(list, const Offset(0, -5500), 5000);
      await tester.pumpAndSettle();
      final controller = tester.widget<SectionScrollView>(list).controller!;
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final calls = repo.catalogs,
          end = controller.position.pixels,
          extent = controller.position.maxScrollExtent;
      expect(find.byType(StretchingOverscrollIndicator), findsNothing);
      for (var i = 0; i < 16; i++) {
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(800, 500),
            scrollDelta: Offset(0, 300),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.position.pixels, end);
        expect(controller.position.maxScrollExtent, extent);
      }
      expect(repo.catalogs, calls);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(repo.stopDownloadWork);
      repositories.remove(repo);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'original direction controls and inline values fit $width with large Italian text',
      (tester) async {
        tester.view.physicalSize = Size(width, 889);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = repository();
        store.setSetting('readerDefault', {
          'pageLayout': 'auto',
          'soloCover': true,
          'showPageShadow': true,
          'controlsGradient': false,
          'background': 'system',
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            locale: const Locale('it'),
            supportedLocales: Strings.locales,
            localizationsDelegates: const [
              Strings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 889),
                textScaler: TextScaler.linear(width < 500 ? 1.4 : 1),
              ),
              child: RepaintBoundary(
                key: key,
                child: DivinaSettingsPage(repository: repo),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Forza direzione di lettura predefinita'),
          findsOneWidget,
        );
        expect(find.text('Da sinistra a destra'), findsOneWidget);
        await screenshot(tester, key, 'divina-settings-${width.toInt()}-dark');
        await tester.tap(
          find.byKey(const ValueKey('preference:readerDefault:direction')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<Object>, 'Webtoon').last,
        );
        await tester.pumpAndSettle();
        expect(
          object(store.setting<dynamic>('readerDefault'))['mode'],
          'webtoon',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(repo.stopDownloadWork);
        repositories.remove(repo);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'reading statistics match reference order with weekly heatmap and status ring at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 889);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            locale: const Locale('it'),
            supportedLocales: Strings.locales,
            localizationsDelegates: const [
              Strings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: SettingsScaffold(
              title: 'Reading Stats',
              backgroundColor: Colors.white,
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: RepaintBoundary(
                  key: key,
                  child: ColoredBox(
                    color: Colors.white,
                    child: ReadingStatsOverview(
                      data: {
                        'summary': {
                          'booksStartedReading': 10,
                          'booksCompletedReading': 5,
                          'totalPagesRead': 1316,
                          'readingDays': 5,
                          'averagePagesPerBook': 263,
                          'totalBooks': 427,
                          'lastReadAt': '2026-10-28T12:00:00Z',
                        },
                        'complete': true,
                        'generatedAt': '2026-10-29T15:40:00Z',
                        'statusDistribution': [
                          {'name': 'unread', 'value': 417},
                          {'name': 'inProgress', 'value': 5},
                          {'name': 'read', 'value': 5},
                        ],
                        'readingTimeSeries': [
                          {'date': '2026-10-28', 'value': 10},
                        ],
                      },
                      library: 'Tutte le librerie',
                      onScope: () {},
                      range: 'last6Months',
                      onRange: (_) {},
                      now: DateTime(2026, 10, 29),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('1.316'), findsOneWidget);
        expect(find.byType(ReadingStatusChart), findsOneWidget);
        if (width >= 700) {
          expect(
            tester
                .getTopLeft(find.widgetWithText(TextButton, 'Ultimi 6 mesi'))
                .dx,
            greaterThan(width * .8),
          );
        }
        expect(
          tester.getTopLeft(find.text('Libri iniziati')).dy,
          lessThan(tester.getTopLeft(find.text('Libri totali')).dy),
        );
        await screenshot(tester, key, 'stats-reference-${width.toInt()}');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('network timeout fields validate edits and persist immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: NetworkSettingsPage(store: store),
      ),
    );
    final input = find.byKey(const ValueKey('input:requestTimeout'));
    await tester.enterText(input, '25');
    expect(store.setting<int>('requestTimeout'), 25);
    await tester.enterText(input, '0');
    expect(store.setting<int>('requestTimeout'), 25);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
