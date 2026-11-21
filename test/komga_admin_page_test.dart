import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/komga_book_management_page.dart';
import 'package:kmreader/features/settings/komga_upload_page.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late LocalStore store;
  late Repository repository;
  late List<http.Request> requests;
  late bool legacy;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('komga-admin-page-');
    store = LocalStore(sqlite3.openInMemory());
    requests = [];
    legacy = false;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: 'fixture',
      client: MockClient((request) async {
        requests.add(request);
        final result = switch ((request.method, request.url.path)) {
          ('GET', '/kmreader-admin/v1/libraries') => {
            'libraries': [
              {'id': 'library', 'name': 'My library'},
            ],
            'max_upload_bytes': 1024 * 1024,
            if (!legacy) 'capabilities': {'folders': true},
          },
          ('GET', '/kmreader-admin/v1/libraries/library/folders') => {
            'folders': request.url.queryParameters['parent'] == null
                ? ['Series A']
                : [],
          },
          ('POST', '/kmreader-admin/v1/libraries/library/folders') => {
            'folder': jsonDecode(request.body)['name'],
          },
          ('GET', '/api/v1/libraries/library') => {'root': '/srv/library'},
          ('POST', '/api/v1/filesystem') => {
            'directories': [
              {'name': 'Series A', 'path': '/srv/library/Series A'},
              {'name': 'Other library', 'path': '/srv/other-library'},
            ],
          },
          _ => null,
        };
        return http.Response(jsonEncode(result), result == null ? 404 : 200);
      }),
    );
    repository = Repository(
      profile: const ServerProfile(
        id: 'fixture',
        name: 'Fixture',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.apiKey,
        admin: true,
      ),
      api: api,
      directory: directory,
      store: store,
    );
  });
  tearDown(() {
    repository.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });

  testWidgets(
    'opening upload page only loads destinations and cannot upload without file selection',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: KomgaUploadPage(repository: repository)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Series folder'), findsOneWidget);
      expect(find.text('Series A'), findsOneWidget);
      expect(find.text('Choose files'), findsOneWidget);
      expect(requests.map((r) => r.method).toList(), ['GET', 'GET']);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Upload to Komga'),
      );
      expect(button.onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a folder is created from the selected library', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: KomgaUploadPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'New series');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('New series'), findsOneWidget);
    final created = requests.singleWhere((r) => r.method == 'POST');
    expect(jsonDecode(created.body), {'name': 'New series', 'parent': ''});
    expect(requests.last.url.queryParameters['parent'], 'New series');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('older upload companion can list folders through Komga', (
    tester,
  ) async {
    legacy = true;
    await tester.pumpWidget(
      MaterialApp(home: KomgaUploadPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Series A'), findsOneWidget);
    expect(find.text('Other library'), findsNothing);
    expect(jsonDecode(requests.last.body), {
      'path': '/srv/library',
      'showFiles': false,
    });
    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'New series');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text('Folder will be created with the first upload.'),
      findsOneWidget,
    );
    expect(requests.length, 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a long upload list scrolls while the send button stays fixed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1024, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    store.setSetting('komgaUpload:fixture', [
      for (var i = 0; i < 50; i++)
        {
          'operation': {
            'id': 'operation-$i',
            'library': 'library',
            'folder': 'Series A',
            'filename': 'Volume $i.cbz',
            'size': 1024,
          },
          'receipt': {'status': 'uploaded', 'scan_requested': true},
        },
    ]);
    await tester.pumpWidget(
      MaterialApp(home: KomgaUploadPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    final send = find.widgetWithText(FilledButton, 'Upload to Komga');
    final queue = find.byKey(const ValueKey('komga-upload-queue'));
    final scrollable = find.descendant(
      of: queue,
      matching: find.byType(Scrollable),
    );
    final buttonRect = tester.getRect(send);
    expect(buttonRect.bottom, lessThan(700));
    expect(tester.getSize(queue).height, lessThanOrEqualTo(420));
    await tester.scrollUntilVisible(
      find.text('Volume 49.cbz'),
      340,
      scrollable: scrollable,
    );
    expect(tester.getRect(send), buttonRect);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'delete names the volume and cancelling confirmation never contacts server',
    (tester) async {
      final book = CatalogItem('books', {
        'id': 'book',
        'metadata': {'title': 'Selected volume'},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: KomgaBookManagementPage(repository: repository, item: book),
        ),
      );
      await tester.tap(find.text('Delete from Komga'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Selected volume\n\n'), findsOneWidget);
      expect(find.textContaining('every user'), findsOneWidget);
      expect(requests, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('Manage on Komga'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
