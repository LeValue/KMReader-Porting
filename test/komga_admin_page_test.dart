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
  setUp(() {
    directory = Directory.systemTemp.createTempSync('komga-admin-page-');
    store = LocalStore(sqlite3.openInMemory());
    requests = [];
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: 'fixture',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'libraries': [
              {'id': 'library', 'name': 'My library'},
            ],
            'max_upload_bytes': 1024 * 1024,
          }),
          200,
        );
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
      expect(find.text('Filename'), findsOneWidget);
      expect(requests.map((r) => r.method).toList(), ['GET']);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Upload to Komga'),
      );
      expect(button.onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
