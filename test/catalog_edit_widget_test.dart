import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/catalog_tools.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/metadata_editor.dart';
import 'package:kmreader/features/catalog/server_smart_lists.dart';
import 'package:kmreader/features/catalog/smart_lists_page.dart';
import 'package:kmreader/ui/strings.dart';

import 'widget_test.dart' show FixtureRepository;

void main() {
  setUpAll(Strings.initialize);
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'catalog editors preserve untouched server fields at ${width.toInt()}px',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync(
          'catalog-edit-ui-',
        );
        final store = LocalStore(sqlite3.openInMemory());
        final requests = <http.Request>[];
        var book = <String, dynamic>{
          'id': 'book',
          'metadata': {
            'title': 'Original',
            'summary': 'Keep this summary',
            'titleLock': false,
          },
          'media': {'pagesCount': 3},
        };
        final smart = <String, dynamic>{
          'id': 'smart',
          'ownerId': 'owner',
          'name': 'Original List',
          'summary': 'Summary',
          'target': 'BOOK',
          'visibility': 'PRIVATE',
          'sharedWithUserIds': <String>[],
          'search': {
            'condition': {
              'futureField': {'operator': 'custom', 'value': 'keep'},
            },
          },
        };
        const profile = ServerProfile(
          id: 's',
          name: 'Test',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
          admin: true,
          userId: 'owner',
        );
        final repository = FixtureRepository(
          profile: profile,
          store: store,
          directory: directory,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: Authentication.apiKey,
            credential: '',
            client: MockClient((request) async {
              requests.add(request);
              if (request.url.path == '/api/v1/smart-lists') {
                return http.Response('', 404);
              }
              if (request.url.path == '/api/v1/smart-lists/smart') {
                return request.method == 'PATCH'
                    ? http.Response('', 204)
                    : http.Response(jsonEncode(smart), 200);
              }
              if (request.method == 'PATCH') {
                book = {
                  ...book,
                  'metadata': {
                    ...object(book['metadata']),
                    ...object(jsonDecode(request.body)),
                  },
                };
                return http.Response('', 204);
              }
              if (request.url.path == '/api/v1/books/book') {
                return http.Response(jsonEncode(book), 200);
              }
              return http.Response(
                jsonEncode({
                  'content': <dynamic>[],
                  'last': true,
                  'totalElements': 0,
                }),
                200,
              );
            }),
          ),
        );
        addTearDown(() {
          repository.dispose();
          store.close();
          directory.deleteSync(recursive: true);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => MetadataEditor(
                        repository: repository,
                        item: CatalogItem('books', book),
                      ),
                    ),
                  ),
                  child: const Text('Open Editor'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open Editor'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'Changed title');
        await tester.tap(find.byIcon(CupertinoIcons.check_mark));
        await tester.pumpAndSettle();
        expect(
          jsonDecode(requests.firstWhere((r) => r.method == 'PATCH').body),
          {'title': 'Changed title', 'titleLock': true},
        );
        expect(object(book['metadata'])['summary'], 'Keep this summary');
        expect(tester.takeException(), isNull);
        requests.clear();
        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey('smart-editor'),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ServerSmartListEditor(
                        repository: repository,
                        item: smart,
                      ),
                    ),
                  ),
                  child: const Text('Open Smart Editor'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open Smart Editor'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'Renamed list');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          jsonDecode(requests.firstWhere((r) => r.method == 'PATCH').body),
          {'name': 'Renamed list'},
        );
        expect(tester.takeException(), isNull);
        requests.clear();
        CatalogTools(repository).savePreset(
          FilterPreset.create(
            'Reader preset',
            'books',
            CatalogFilter(
              entries: [
                {'field': 'tag', 'operator': 'is', 'value': 'comic'},
              ],
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey('smart-browser'),
            home: Scaffold(body: SmartListsPage(repository: repository)),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('This feature requires a kmrs server.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Saved Filters'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reader preset'));
        await tester.pumpAndSettle();
        final search = requests.firstWhere(
          (r) => r.url.path == '/api/v1/books/list',
        );
        expect(jsonDecode(search.body)['condition'], {
          'tag': {'operator': 'is', 'value': 'comic'},
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
