import 'dart:async';
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
import 'package:kmreader/features/catalog/refresh_cover_button.dart';
import 'package:kmreader/features/catalog/server_smart_lists.dart';
import 'package:sqlite3/sqlite3.dart';

class _NetworkRepository extends Repository {
  _NetworkRepository({
    required super.profile,
    required super.api,
    required super.store,
    required super.directory,
  });
  @override
  Future<Uint8List> image(String path, {bool refresh = false}) =>
      api.bytes(path);
}

void main() {
  for (final kind in [
    'books',
    'series',
    'collections',
    'readlists',
    'smart-lists',
  ]) {
    test(
      '$kind cover refresh fetches fresh art without administrative mutations',
      () async {
        final directory = Directory.systemTemp.createTempSync('cover-refresh-');
        final store = LocalStore(sqlite3.openInMemory());
        final calls = <http.Request>[];
        final api = KomgaApi(
          Uri.parse('https://example.invalid/prefix'),
          authentication: Authentication.apiKey,
          credential: '',
          client: MockClient((request) async {
            calls.add(request);
            return http.Response.bytes([calls.length], 200);
          }),
        );
        final repo = Repository(
          profile: const ServerProfile(
            id: 'fixture',
            name: 'Fixture',
            url: 'https://example.invalid/prefix',
            email: '',
            authentication: Authentication.apiKey,
          ),
          api: api,
          store: store,
          directory: directory,
        );
        final item = CatalogItem(kind, {'id': 'item'});
        try {
          expect(await repo.image(item.thumbnail), [1]);
          await repo.refreshCover(item);
          expect(await repo.image(item.thumbnail), [2]);
          expect(calls.map((r) => r.method), ['GET', 'GET']);
          expect(calls.last.url.path, '/prefix/api/v1/$kind/item/thumbnail');
          expect(repo.imageChanges.value, {item.thumbnail});
          repo.offline = true;
          await expectLater(
            repo.refreshCover(item),
            throwsA(isA<ApiFailure>()),
          );
          expect(calls, hasLength(2));
          expect(await repo.cachedFile(item.thumbnail).exists(), true);
        } finally {
          repo.dispose();
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
  testWidgets(
    'read-only smart-list menu refreshes cover through its callback',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('smart-cover-');
      final store = LocalStore(sqlite3.openInMemory());
      final paths = <String>[];
      final api = KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.apiKey,
        credential: '',
        client: MockClient((request) async {
          expect(request.method, 'GET');
          paths.add(request.url.path);
          if (request.url.path.endsWith('/thumbnail')) {
            return http.Response.bytes([1], 200);
          }
          return http.Response(
            jsonEncode([
              {
                'id': 'smart',
                'name': 'Synthetic list',
                'target': 'BOOK',
                'ownerId': 'other',
                'visibility': 'PUBLIC',
              },
            ]),
            200,
          );
        }),
      );
      final repo = _NetworkRepository(
        profile: const ServerProfile(
          id: 'fixture',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
          userId: 'reader',
        ),
        api: api,
        store: store,
        directory: directory,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ServerSmartListsPage(repository: repo)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh cover'));
        await tester.pumpAndSettle();
        expect(paths, contains('/api/v1/smart-lists/smart/thumbnail'));
        await tester.pumpWidget(const SizedBox());
      } finally {
        repo.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('refresh button prevents repeated taps and disables offline', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('cover-button-');
    final store = LocalStore(sqlite3.openInMemory());
    var calls = 0;
    final response = Completer<http.Response>();
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient((_) async {
        calls++;
        return response.future;
      }),
    );
    final repo = _NetworkRepository(
      profile: const ServerProfile(
        id: 'fixture',
        name: 'Fixture',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.apiKey,
      ),
      api: api,
      store: store,
      directory: directory,
    );
    try {
      Widget app() => MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              RefreshCoverButton(
                repository: repo,
                item: CatalogItem('books', {'id': 'item'}),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.tap(find.byTooltip('Refresh cover'));
      await tester.pump();
      await tester.tap(find.byTooltip('Refresh cover'));
      await tester.pump();
      expect(calls, 1);
      response.complete(http.Response('', 404));
      await tester.pumpAndSettle();
      repo.setOffline(true);
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    } finally {
      repo.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
}
