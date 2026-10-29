import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/main.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/features/settings/settings_page.dart';

class MemoryVault implements CredentialVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class FixtureRepository extends Repository {
  FixtureRepository({
    required super.profile,
    required super.api,
    required super.store,
    required super.directory,
  });
  static final bytes = File('test/fixtures/page.png').readAsBytesSync();
  @override
  Future<Uint8List> image(String path, {bool refresh = false}) async => bytes;
  @override
  Future<Uint8List> page(String id, int page) async => bytes;
  @override
  Future<Uint8List> prefetchPage(String id, int page) async => bytes;
}

Future<void> screenshot(WidgetTester tester, GlobalKey key, String name) async {
  final path = Platform.environment['KMREADER_SCREENSHOT_DIR'];
  if (path == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$path/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final font in manifest) {
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
        final loader = FontLoader('Segoe UI')
          ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
        await loader.load();
        return;
      }
      directory = directory.parent;
    }
    throw StateError(
      'Flutter material fonts are required for widget rendering tests.',
    );
  });
  late AppController app;
  late Directory directory;
  setUp(() async {
    await Strings.initialize();
    directory = Directory.systemTemp.createTempSync('kmreader-widget-');
    app = AppController(
      store: LocalStore(sqlite3.openInMemory()),
      directory: directory,
      vault: MemoryVault(),
    );
    app.setLanguage('en');
  });
  tearDown(() {
    app.repository?.dispose();
    app.store.close();
    directory.deleteSync(recursive: true);
  });
  for (final size in [const Size(390, 844), const Size(1280, 889)]) {
    testWidgets('catalog detail and reader work at ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const profile = ServerProfile(
        id: 'fixture',
        name: 'My Library',
        url: 'https://example.invalid',
        email: 'reader@example.invalid',
        authentication: Authentication.password,
      );
      final book = {
        'id': 'book',
        'seriesId': 'series',
        'libraryId': 'library',
        'seriesTitle': 'Example Series',
        'name': 'Synthetic Comic.cbz',
        'media': {'pagesCount': 3, 'mediaType': 'application/zip'},
        'metadata': {
          'title': 'Synthetic Comic',
          'summary': 'A synthetic book used to exercise the reader.',
        },
      };
      app.store.saveServer(profile);
      final requests = <http.Request>[];
      final repository = FixtureRepository(
        profile: profile,
        store: app.store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: Authentication.password,
          credential: 'synthetic',
          client: MockClient((request) async {
            requests.add(request);
            if (request.method == 'PATCH') return http.Response('', 204);
            if (request.url.path.endsWith('/books/book')) {
              return http.Response(jsonEncode(book), 200);
            }
            if (request.url.path.endsWith('/libraries')) {
              return http.Response('[{"id":"library","name":"Comics"}]', 200);
            }
            final isBooks = request.url.path.contains('/books');
            final values = isBooks
                ? [book]
                : request.url.path.contains('/series')
                ? [
                    {
                      'id': 'series',
                      'name': 'Example Series',
                      'booksCount': 1,
                      'metadata': {'title': 'Example Series'},
                    },
                  ]
                : [];
            return http.Response(
              jsonEncode({
                'content': values,
                'last': true,
                'totalElements': values.length,
              }),
              200,
            );
          }),
        ),
      );
      app.repository = repository;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: KMReaderApp(app: app),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(FixtureRepository.bytes),
          tester.element(find.byType(KMReaderApp)),
        ),
      );
      for (final width in [128, 256, 512, 1024]) {
        await tester.runAsync(
          () => precacheImage(
            ResizeImage.resizeIfNeeded(
              width,
              null,
              MemoryImage(FixtureRepository.bytes),
            ),
            tester.element(find.byType(KMReaderApp)),
          ),
        );
      }
      await tester.runAsync(
        () => precacheImage(
          ResizeImage.resizeIfNeeded(
            size.width.ceil(),
            null,
            MemoryImage(FixtureRepository.bytes),
          ),
          tester.element(find.byType(KMReaderApp)),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      expect(tester.takeException(), isNull);
      expect(
        requests.where(
          (r) =>
              r.url.path.contains('readlists') ||
              r.url.path.contains('collections') ||
              r.url.path.endsWith('/libraries'),
        ),
        isEmpty,
        reason: 'Unvisited tabs must not start network requests',
      );
      expect(requests.length, 7);
      for (final style in ['Medium', 'Horizontal']) {
        await tester.tap(find.byTooltip('Card Style').first);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, style),
        );
        await tester.pumpAndSettle();
        expect(
          app.store.setting<String>(
            'dashboardCard:fixture:dashboard.keepReading',
          ),
          style.toLowerCase(),
        );
        expect(
          requests.length,
          7,
          reason: 'Changing card presentation must reuse cached results',
        );
      }
      await tester.tap(find.text('All Libraries'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Comics'));
      await tester.pumpAndSettle();
      expect(
        object(app.store.setting<dynamic>('dashboardLibrary:fixture'))['id'],
        'library',
      );
      expect(
        requests.any(
          (r) =>
              r.url.path.endsWith('/ondeck') &&
              r.url.queryParameters['library_id'] == 'library',
        ),
        isTrue,
      );
      await screenshot(tester, key, 'dashboard-${size.width.toInt()}');
      final title = find.text('Synthetic Comic').first;
      await tester.ensureVisible(title);
      await tester.tap(title);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      expect(
        find.text('A synthetic book used to exercise the reader.'),
        findsOneWidget,
      );
      final read = find.byType(FilledButton).first;
      await tester.ensureVisible(read);
      await tester.tap(read);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.tap(find.byIcon(CupertinoIcons.chevron_right));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      expect(find.text('2 / 3'), findsOneWidget);
      expect(repository.store.progress(profile.id, 'book'), isNotNull);
      expect(repository.store.progress(profile.id, 'book')!['page'], 2);
      expect(tester.takeException(), isNull);
      await screenshot(tester, key, 'reader-${size.width.toInt()}');
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      final settingsScroll = find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Theme'),
        300,
        scrollable: settingsScroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'System').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light').last);
      await tester.pumpAndSettle();
      expect(app.theme, ThemeMode.light);
      await tester.tap(find.widgetWithText(TextButton, 'English'));
      await tester.pumpAndSettle();
      await screenshot(tester, key, 'language-menu-${size.width.toInt()}');
      await tester.tap(find.text('Italiano'));
      await tester.pumpAndSettle();
      expect(app.language, 'it');
      expect(tester.takeException(), isNull);
      await screenshot(tester, key, 'settings-${size.width.toInt()}');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await screenshot(tester, key, 'settings-index-${size.width.toInt()}');
      await tester.tap(find.widgetWithText(ListTile, 'Esplora'));
      await tester.pumpAndSettle();
      expect(find.text('Overlay testo schede'), findsOneWidget);
      if (size.width >= 900) expect(find.text('My Library'), findsOneWidget);
      await screenshot(tester, key, 'browse-settings-${size.width.toInt()}');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      final dashboardSettings = find.widgetWithText(ListTile, 'Dashboard').last;
      await tester.scrollUntilVisible(
        dashboardSettings,
        -300,
        scrollable: settingsScroll,
      );
      await tester.pumpAndSettle();
      final countBeforeReorder = requests.length;
      await tester.tap(dashboardSettings);
      await tester.pumpAndSettle();
      await tester.drag(
        find.byIcon(CupertinoIcons.line_horizontal_3).first,
        const Offset(0, 100),
      );
      await tester.pumpAndSettle();
      final order = app.store.setting<List<dynamic>>('dashboardOrder:fixture');
      expect(order, isNotNull);
      expect(order!.length, 8);
      expect(order.first, isNot('dashboard.keepReading'));
      expect(
        requests.length,
        countBeforeReorder,
        reason: 'Reordering cached sections must not refetch catalog data',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets(
      'onboarding and sign-in fit ${size.width.toInt()}px without layout errors',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: KMReaderApp(app: app),
          ),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 10),
        );
        expect(find.text('KMReader'), findsOneWidget);
        expect(find.text('Get Started'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await screenshot(tester, boundary, 'onboarding-${size.width.toInt()}');
        await tester.tap(find.text('Get Started'));
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 10),
        );
        expect(find.text('Connect to Komga'), findsOneWidget);
        await tester.ensureVisible(find.text('Sign In'));
        await tester.tap(find.text('Sign In'));
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 10),
        );
        expect(find.text('Required'), findsNWidgets(2));
        expect(app.servers, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
