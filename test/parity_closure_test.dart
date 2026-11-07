import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/reading_stats.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/server_event.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('all upstream catalog and progress event families are mapped; unknown messages cannot refresh', () {
    for (final (prefix, kind, field) in [
      ('Library', 'libraries', 'libraryId'),
      ('Series', 'series', 'seriesId'),
      ('Book', 'books', 'bookId'),
      ('Collection', 'collections', 'collectionId'),
      ('ReadList', 'readlists', 'readListId'),
      ('SmartList', 'smart-lists', 'smartListId'),
    ]) {
      for (final action in ['Added', 'Changed', 'Deleted']) {
        expect(catalogEventChange('$prefix$action', {field: 'id'}), (
          kind: kind,
          id: 'id',
          deleted: action == 'Deleted',
        ));
      }
    }
    expect(catalogEventChange('ReadProgressDeleted', {'bookId': 'b'}), (
      kind: 'books',
      id: 'b',
      deleted: false,
    ));
    expect(catalogEventChange('ReadProgressSeriesChanged', {'seriesId': 's'}), (
      kind: 'series',
      id: 's',
      deleted: false,
    ));
    for (final type in [
      'message',
      'heartbeat',
      'TaskQueueStatus',
      'UnknownChanged',
    ]) {
      expect(catalogEventChange(type, {}), null);
    }
  });

  test('SSE deletion removes offline metadata, retains originals/progress and rejects a late detail reply', () async {
    final root = Directory.systemTemp.createTempSync('parity-events-');
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'one',
      name: 'One',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
      userId: 'user',
    );
    final events = StreamController<List<int>>();
    final started = Completer<void>(),
        response = Completer<http.StreamedResponse>();
    final repo = Repository(
      profile: profile,
      store: store,
      directory: root,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: Authentication.apiKey,
        credential: '',
        client: MockClient.streaming((request, _) async {
          if (request.url.path == '/sse/v1/events') {
            return http.StreamedResponse(events.stream, 200);
          }
          if (request.url.path.endsWith('/books/book')) {
            started.complete();
            return response.future;
          }
          return http.StreamedResponse(Stream.value(utf8.encode('[]')), 200);
        }),
      ),
    );
    addTearDown(() async {
      await repo.stopDownloadWork();
      await events.close();
      store.close();
      root.deleteSync(recursive: true);
    });
    final book = Book({
      'id': 'book',
      'seriesId': 'series',
      'libraryId': 'lib',
      'metadata': {'title': 'Title'},
    });
    repo.rememberItem(CatalogItem('books', book.json));
    store.cache('two', 'book:book', book.json);
    store.recordProgress(profile.id, book.id, {'page': 3});
    store.setSetting('offlineCatalogSnapshot:one', {'complete': true});
    final file = repo.bookFile(book);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('protected');
    repo.listen();
    final late = repo.get(
      '/api/v1/books/book',
      cacheKey: 'book:book',
      force: true,
    );
    await started.future;
    events.add(utf8.encode('event: BookDeleted\ndata: {"bookId":"book"}\n\n'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    response.complete(
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(book.json))),
        200,
      ),
    );
    await late;
    expect(store.cached(profile.id, 'book:book'), null);
    expect(store.offlineCatalog.count(profile.id, 'books'), 0);
    expect(store.cached('two', 'book:book'), isNotNull);
    expect(store.progress(profile.id, 'book')?['page'], 3);
    expect(file.readAsStringSync(), 'protected');
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(repo.contentRevision, 1);
    expect(
      object(store.setting<dynamic>('offlineCatalogSnapshot:one'))['complete'],
      false,
    );
    events.add(
      utf8.encode(
        'event: ReadProgressChanged\ndata: {"bookId":"book","userId":"another-user"}\n\n',
      ),
    );
    events.add(utf8.encode('event: heartbeat\ndata: {}\n\n'));
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(repo.contentRevision, 1);
    store.setSetting('enableSSEAutoRefresh', false);
    events.add(utf8.encode('event: BookAdded\ndata: {"bookId":"other"}\n\n'));
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(repo.contentRevision, 1);
  });

  test('fresh server lists recover missed additions, but a list started before deletion cannot restore a removed book', () async {
    final root = Directory.systemTemp.createTempSync('parity-restore-');
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'one',
      name: 'One',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    final events = StreamController<List<int>>();
    final started = Completer<void>(), old = Completer<http.StreamedResponse>();
    var lists = 0;
    final dto = {
      'id': 'book',
      'metadata': {'title': 'Book'},
    };
    List<int> body() => utf8.encode(
      jsonEncode({
        'content': [dto],
        'last': true,
        'totalElements': 1,
      }),
    );
    final repo = Repository(
      profile: profile,
      store: store,
      directory: root,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: Authentication.apiKey,
        credential: '',
        client: MockClient.streaming((request, _) async {
          if (request.url.path == '/sse/v1/events') {
            return http.StreamedResponse(events.stream, 200);
          }
          if (request.url.path == '/api/v1/books/list') {
            lists++;
            if (lists == 1) {
              started.complete();
              return old.future;
            }
            return http.StreamedResponse(Stream.value(body()), 200);
          }
          return http.StreamedResponse(Stream.value(utf8.encode('[]')), 200);
        }),
      ),
    );
    addTearDown(() async {
      await repo.stopDownloadWork();
      await events.close();
      store.close();
      root.deleteSync(recursive: true);
    });
    repo.listen();
    final delayed = repo.catalog('books', force: true);
    await started.future;
    events.add(utf8.encode('event: BookDeleted\ndata: {"bookId":"book"}\n\n'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    old.complete(http.StreamedResponse(Stream.value(body()), 200));
    expect((await delayed).items, isEmpty);
    expect(store.offlineCatalog.count(profile.id, 'books'), 0);
    // No Added event is emitted: the authoritative fresh list must reconcile it.
    expect((await repo.catalog('books', force: true)).items.single.id, 'book');
    expect(store.offlineCatalog.count(profile.id, 'books'), 1);
    expect(store.setting<List<dynamic>>('removed:one'), isEmpty);
  });

  for (final autoRefresh in [false, true]) {
    test(
      'SSE reconnect reconciles missed updates only when enabled; autoRefresh=$autoRefresh',
      () async {
        final root = Directory.systemTemp.createTempSync('parity-reconnect-');
        final store = LocalStore(sqlite3.openInMemory());
        store.setSetting('enableSSEAutoRefresh', autoRefresh);
        const profile = ServerProfile(
          id: 'one',
          name: 'One',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
          userId: 'user',
        );
        final first = StreamController<List<int>>(),
            second = StreamController<List<int>>();
        var connections = 0;
        final repo = Repository(
          profile: profile,
          store: store,
          directory: root,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: Authentication.apiKey,
            credential: '',
            client: MockClient.streaming((request, _) async {
              if (request.url.path == '/sse/v1/events') {
                connections++;
                if (connections > 1) {
                  expect(request.headers['Last-Event-ID'], '42');
                }
                return http.StreamedResponse(
                  connections == 1 ? first.stream : second.stream,
                  200,
                );
              }
              return http.StreamedResponse(
                Stream.value(utf8.encode('[]')),
                200,
              );
            }),
          ),
        );
        addTearDown(() async {
          await repo.stopDownloadWork();
          await second.close();
          store.close();
          root.deleteSync(recursive: true);
        });
        repo.listen();
        first.add(
          utf8.encode('id: 42\nevent: TaskQueueStatus\ndata: {"count":1}\n\n'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await first.close();
        await Future<void>.delayed(const Duration(milliseconds: 10200));
        expect(connections, 2);
        second.add(utf8.encode('event: message\ndata: {}\n\n'));
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(repo.contentRevision, autoRefresh ? 1 : 0);
        second.add(
          utf8.encode(
            'event: SessionExpired\ndata: {"userId":"another-user"}\n\n',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          repo.eventNotices.value,
          isNot('Session expired. Reconnect your account.'),
        );
        second.add(
          utf8.encode('event: SessionExpired\ndata: {"userId":"user"}\n\n'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          repo.eventNotices.value,
          'Session expired. Reconnect your account.',
        );
        repo.listen();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(connections, 2);
      },
    );
  }

  for (final incomplete in [false, true]) {
    test(
      'offline statistics use the full indexed metadata and distinguish ${incomplete ? 'interrupted' : 'complete'} snapshots without network',
      () async {
        final root = Directory.systemTemp.createTempSync('parity-stats-');
        final store = LocalStore(sqlite3.openInMemory());
        const profile = ServerProfile(
          id: 'one',
          name: 'One',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        );
        var requests = 0;
        final repo = Repository(
          profile: profile,
          store: store,
          directory: root,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: Authentication.apiKey,
            credential: '',
            client: MockClient((_) async {
              requests++;
              return http.Response('', 500);
            }),
          ),
        )..setOffline(true);
        addTearDown(() async {
          await repo.stopDownloadWork();
          store.close();
          root.deleteSync(recursive: true);
        });
        store.setSetting('offlineCatalogSnapshot:one', {
          'complete': !incomplete,
          'inProgress': incomplete,
          'modified': '2026-11-07T10:00:00Z',
        });
        for (final (server, library, id) in [
          ('one', 'wanted', 'read'),
          ('one', 'wanted', 'unread'),
          ('one', 'other', 'elsewhere'),
          ('two', 'wanted', 'other-account'),
        ]) {
          store.cache(server, 'book:$id', {
            'id': id,
            'seriesId': 'series',
            'libraryId': library,
            'media': {'pagesCount': 12},
            'metadata': {
              'authors': [
                {'name': 'Author'},
              ],
            },
            if (id == 'read')
              'readProgress': {
                'page': 12,
                'completed': true,
                'readDate': '2026-11-07T10:00:00Z',
              },
          });
        }
        for (var i = 0; i < 205; i++) {
          store.cache('one', 'book:extra-$i', {
            'id': 'extra-$i',
            'libraryId': 'wanted',
            'metadata': {'title': 'Extra $i'},
          });
        }
        store.cache('one', 'detail:series:series', {
          'id': 'series',
          'libraryId': 'wanted',
          'metadata': {
            'genres': ['Adventure'],
            'tags': ['Tag'],
          },
        });
        final stats = await ReadingStats(repo).load(libraryId: 'wanted');
        expect(requests, 0);
        expect(stats['source'], 'offline-index');
        expect(stats['complete'], !incomplete);
        expect(object(stats['summary'])['totalBooks'], 207);
        expect(object(stats['summary'])['booksCompletedReading'], 1);
        expect(stats['topGenres'], [
          {'name': 'Adventure', 'value': 1},
        ]);
        expect(stats['generatedAt'], '2026-11-07T10:00:00Z');
      },
    );
  }
}
