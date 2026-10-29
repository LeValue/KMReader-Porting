import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/browse_preferences.dart';
import 'package:kmreader/core/catalog_tools.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/catalog_page.dart';
import 'package:kmreader/features/settings/browse_settings.dart';
import 'package:kmreader/features/settings/settings_page.dart';
import 'package:kmreader/ui/common.dart';
import 'package:kmreader/ui/strings.dart';

import 'widget_test.dart' show FixtureRepository, MemoryVault;

void main() {
  late LocalStore store;
  late Directory directory;
  late FixtureRepository repository;
  final requests = <http.Request>[];
  setUpAll(Strings.initialize);
  setUp(() {
    requests.clear();
    store = LocalStore(sqlite3.openInMemory());
    directory = Directory.systemTemp.createTempSync('kmreader-browse-');
    const profile = ServerProfile(
      id: 'browse',
      name: 'Browse',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.password,
    );
    repository = FixtureRepository(
      profile: profile,
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: Authentication.password,
        credential: '',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({'content': [], 'last': true, 'totalElements': 0}),
            200,
          );
        }),
      ),
    );
  });
  tearDown(() {
    repository.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });

  testWidgets('live card options persist and do not reload images or catalog', (
    tester,
  ) async {
    final item = CatalogItem('books', {
      'id': 'book',
      'name': 'A book',
      'seriesTitle': 'A series',
      'media': {'pagesCount': 20},
      'readProgress': {'page': 5},
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 300,
            child: BookCard(repository: repository, item: item),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('A series'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<Cover>(find.byType(Cover)).fit, BoxFit.contain);
    repository.browse.set(BrowseOption.seriesTitle, false);
    repository.browse.set(BrowseOption.progress, false);
    repository.browse.set(BrowseOption.shadow, false);
    await tester.pump();
    expect(find.text('A series'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    repository.browse.set(BrowseOption.coverOnly, true);
    await tester.pump();
    expect(find.text('A book'), findsNothing);
    expect(find.bySemanticsLabel('A book'), findsOneWidget);
    repository.browse.set(BrowseOption.textOverlay, true);
    await tester.pump();
    expect(find.text('A book'), findsOneWidget);
    expect(tester.widget<Cover>(find.byType(Cover)).fit, BoxFit.cover);
    repository.browse.set(BrowseOption.textOverlay, false);
    await tester.pump();
    expect(find.text('A book'), findsNothing);
    final reopened = BrowsePreferences(store);
    expect(reopened.hidesText, isTrue);
    expect(reopened[BrowseOption.seriesTitle], isFalse);
    reopened.dispose();
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'preserved cover geometry places badges on the image and starts blur only before reading',
    (tester) async {
      final item = CatalogItem('series', {
        'id': 'series',
        'name': 'Series',
        'booksCount': 12,
        'booksUnreadCount': 11,
        'booksInProgressCount': 1,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 160,
                height: 400,
                child: BookCard(repository: repository, item: item),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          ResizeImage.resizeIfNeeded(
            256,
            null,
            MemoryImage(FixtureRepository.bytes),
          ),
          tester.element(find.byType(Scaffold)),
        ),
      );
      await tester.pumpAndSettle();
      final image = tester.getRect(find.byType(RawImage));
      expect(image.size, const Size(160, 240));
      expect(tester.getRect(find.text('11')).top, closeTo(image.top + 4, .01));
      repository.browse.set(BrowseOption.blurUnread, true);
      await tester.pump();
      expect(find.byType(ImageFiltered), findsNothing);
      repository.browse.set(BrowseOption.preserveAspectRatio, false);
      await tester.pump();
      expect(
        tester.getSize(find.byType(RawImage)).height,
        greaterThan(image.height),
      );
      repository.browse.set(BrowseOption.badges, false);
      await tester.pump();
      expect(find.text('11'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'settings back navigation is handled only while its tab is active',
    (tester) async {
      final app = AppController(
        store: store,
        directory: directory,
        vault: MemoryVault(),
      );
      final root = GlobalKey<NavigatorState>();
      var active = true;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: root,
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => update(() => active = !active),
                    child: const Text('Toggle tab'),
                  ),
                  Expanded(
                    child: Offstage(
                      offstage: !active,
                      child: TickerMode(
                        enabled: active,
                        child: SettingsPage(app: app, repository: repository),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      expect(find.text('Theme'), findsOneWidget);
      expect(await root.currentState!.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Theme'), findsNothing);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Toggle tab'));
      await tester.pumpAndSettle();
      expect(await root.currentState!.maybePop(), isFalse);
      await tester.tap(find.text('Toggle tab'));
      await tester.pumpAndSettle();
      expect(find.byType(BrowseSettingsPage), findsOneWidget);
      expect(await root.currentState!.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(BrowseSettingsPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'browse preview and dependent options work at $width with large text',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: BrowseSettingsPage(preferences: repository.browse),
          ),
        );
        final overlay = find.byKey(const ValueKey(BrowseOption.textOverlay));
        await tester.ensureVisible(overlay);
        await tester.pumpAndSettle();
        await tester.tap(overlay);
        await tester.pumpAndSettle();
        expect(repository.browse.overlaysText, isTrue);
        expect(
          find.byKey(const ValueKey(BrowseOption.coverOnly)),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey(BrowseOption.preserveAspectRatio)),
          findsNothing,
        );
        await tester.tap(overlay);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey(BrowseOption.coverOnly)),
          findsOneWidget,
        );
        for (final option in [
          BrowseOption.badges,
          BrowseOption.blurUnread,
          BrowseOption.progress,
        ]) {
          final toggle = find.byKey(ValueKey(option));
          await tester.ensureVisible(toggle);
          await tester.pumpAndSettle();
          await tester.tap(toggle);
          await tester.pumpAndSettle();
        }
        expect(repository.browse[BrowseOption.badges], isFalse);
        expect(repository.browse[BrowseOption.blurUnread], isTrue);
        expect(repository.browse[BrowseOption.progress], isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'search filter bypass retains scope and select-all uses the same library and condition',
    (tester) async {
      const scope = {
        'libraryId': {'operator': 'is', 'value': 'scope'},
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogPageView(
              repository: repository,
              kind: 'books',
              condition: scope,
              libraryId: 'scope',
              initialSearch: 'comic',
              initialFilter: CatalogFilter(
                entries: [
                  {'field': 'tag', 'operator': 'is', 'value': 'tag'},
                ],
              ),
              onPicked: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(requests.last.body, contains('tag'));
      repository.browse.set(BrowseOption.ignoreSearchFilters, true);
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));
      final searching = jsonDecode(requests.last.body);
      expect(searching, {'condition': scope, 'fullTextSearch': 'comic'});
      await tester.tap(find.byTooltip('Select All'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select All Results'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(3));
      expect(jsonDecode(requests.last.body), searching);
      expect(requests.last.url.queryParameters['library_id'], 'scope');
      expect(requests.last.url.queryParameters['size'], '200');
      await tester.tap(find.byIcon(CupertinoIcons.clear_circled_solid));
      await tester.pumpAndSettle();
      expect(requests.last.body, contains('tag'));
      expect(requests.last.body, isNot(contains('fullTextSearch')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
