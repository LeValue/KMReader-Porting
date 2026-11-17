import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/komga_book_management_page.dart';
import 'package:sqlite3/sqlite3.dart';

class _Repository extends Repository {
  _Repository({
    required super.profile,
    required super.api,
    required super.store,
    required super.directory,
  });
  final png = File('test/fixtures/page.png').readAsBytesSync();
  @override
  Future<Uint8List> image(String path, {bool refresh = false}) async => png;
}

void main() {
  for (final kind in ['books', 'series']) {
    testWidgets(
      '$kind cover gallery restores original, cancels removal, then removes only uploaded art',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('cover-page-');
        final store = LocalStore(sqlite3.openInMemory())
          ..setSetting('enableReadListSync', false);
        final writes = <String>[];
        var selected = 'upload', removed = false;
        final owner = kind == 'books' ? 'bookId' : 'seriesId';
        final api = KomgaApi(
          Uri.parse('https://example.invalid'),
          authentication: Authentication.apiKey,
          credential: '',
          client: MockClient((request) async {
            if (request.method != 'GET') writes.add(request.method);
            if (request.method == 'PUT') selected = 'original';
            if (request.method == 'DELETE') removed = true;
            if (request.url.path.endsWith('/thumbnails')) {
              return http.Response(
                jsonEncode([
                  {
                    'id': 'original',
                    owner: 'item',
                    'type': 'GENERATED',
                    'selected': selected == 'original',
                  },
                  if (!removed)
                    {
                      'id': 'upload',
                      owner: 'item',
                      'type': 'USER_UPLOADED',
                      'selected': selected == 'upload',
                    },
                ]),
                200,
              );
            }
            return http.Response('{"seriesId":"parent"}', 200);
          }),
        );
        final repo = _Repository(
          profile: const ServerProfile(
            id: 'fixture',
            name: 'Fixture',
            url: 'https://example.invalid',
            email: '',
            authentication: Authentication.apiKey,
            admin: true,
          ),
          api: api,
          store: store,
          directory: directory,
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: KomgaBookManagementPage(
                repository: repo,
                item: CatalogItem(kind, {
                  'id': 'item',
                  'metadata': {'title': 'Fixture volume'},
                }),
              ),
            ),
          );
          await tester.tap(find.text('Available covers'));
          await tester.pumpAndSettle();
          expect(find.text('Current cover'), findsOneWidget);
          expect(writes, isEmpty);
          await tester.tap(find.text('From document 1'));
          await tester.pumpAndSettle();
          expect(writes, ['PUT']);
          // Generated document art has no delete button.
          expect(find.byTooltip('Remove uploaded cover'), findsOneWidget);
          await tester.tap(find.byTooltip('Remove uploaded cover'));
          await tester.pumpAndSettle();
          expect(find.textContaining('book file are kept'), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(writes, ['PUT']);
          await tester.tap(find.byTooltip('Remove uploaded cover'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Continue'));
          await tester.pumpAndSettle();
          expect(writes, ['PUT', 'DELETE']);
          expect(find.text('Uploaded cover 2'), findsNothing);
          expect(find.text('From document 1'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        } finally {
          repo.dispose();
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
}
