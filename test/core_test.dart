import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/reading_session.dart';

const profile = ServerProfile(
  id: 'test-server',
  name: 'Test',
  url: 'https://example.invalid/komga',
  email: 'test@example.invalid',
  authentication: Authentication.password,
);
Book sampleBook([String id = 'book']) => Book({
  'id': id,
  'seriesId': 'series',
  'libraryId': 'library',
  'name': 'Test.cbz',
  'metadata': {'title': 'Test'},
  'media': {'pagesCount': 5, 'mediaType': 'application/zip'},
});

void main() {
  group('Server and API contract', () {
    test('normalizes reverse proxy base paths without credentials', () {
      expect(
        normalizeServerUrl(' example.org/komga/// ').toString(),
        'https://example.org/komga',
      );
      expect(
        normalizeServerUrl('http://127.0.0.1:25600/').toString(),
        'http://127.0.0.1:25600',
      );
      for (final url in [
        'ftp://example.org',
        'https://a:b@example.org',
        'https://example.org/?token=secret',
        'https://example.org/#x',
      ]) {
        expect(() => normalizeServerUrl(url), throwsFormatException);
      }
    });
    test('preserves base path, repeated filters, Unicode and explicit authentication', () async {
      final api = KomgaApi(
        Uri.parse(profile.url),
        authentication: Authentication.password,
        credential: 'synthetic',
        client: MockClient((request) async {
          expect(request.url.path, '/komga/api/v1/books/list');
          expect(request.url.queryParametersAll['library_id'], ['one', 'two']);
          expect(request.headers['Authorization'], 'Basic synthetic');
          expect(request.followRedirects, isFalse);
          expect(jsonDecode(request.body)['fullTextSearch'], '漫画');
          return http.Response(
            '{"content":[],"last":true,"totalElements":0}',
            200,
          );
        }),
      );
      await api.request(
        '/api/v1/books/list',
        method: 'POST',
        body: {'fullTextSearch': '漫画'},
        query: {
          'library_id': ['one', 'two'],
        },
      );
      expect(() => api.uri('https://other.invalid/'), throwsArgumentError);
      expect(() => api.uri('//other.invalid/'), throwsArgumentError);
      api.close();
    });
    test(
      'API key never becomes Basic authentication and 401 is not offline',
      () async {
        final api = KomgaApi(
          Uri.parse(profile.url),
          authentication: Authentication.apiKey,
          credential: 'synthetic-key',
          client: MockClient((request) async {
            expect(request.headers['X-API-Key'], 'synthetic-key');
            expect(request.headers.containsKey('Authorization'), isFalse);
            return http.Response('private server response', 401);
          }),
        );
        await expectLater(
          api.user(),
          throwsA(
            isA<ApiFailure>()
                .having((e) => e.status, 'status', 401)
                .having((e) => e.offline, 'offline', false)
                .having(
                  (e) => e.message.contains('private server response'),
                  'redacted body',
                  false,
                ),
          ),
        );
        api.close();
      },
    );
  });
  group('Durable local data', () {
    late LocalStore store;
    setUp(() => store = LocalStore(sqlite3.openInMemory()));
    tearDown(() => store.close());
    test(
      'null settings and server-isolated caches survive independent mutations',
      () {
        store.setSetting('language', null);
        expect(store.setting<String>('language'), isNull);
        store.cache('a', 'book', {'title': 'A'});
        store.cache('b', 'book', {'title': 'B'});
        store.removeServer('a');
        expect(store.cached('a', 'book'), isNull);
        expect(store.cached('b', 'book')['title'], 'B');
      },
    );
    test(
      'acknowledging a sent revision cannot discard a newer offline edit',
      () {
        store.recordProgress('a', 'book', {'page': 2});
        final sent = store.pending('a').single;
        store.recordProgress('a', 'book', {'page': 4});
        store.acknowledge('a', 'book', sent['revision']);
        expect(store.pending('a').single['value']['page'], 4);
        store.acknowledge('a', 'book', store.pending('a').single['revision']);
        expect(store.pending('a'), isEmpty);
        expect(store.progress('a', 'book')!['page'], 4);
      },
    );
  });
  group('Repository offline and synchronization', () {
    late LocalStore store;
    late Directory directory;
    late Repository repository;
    final sent = <int>[];
    setUp(() {
      sent.clear();
      store = LocalStore(sqlite3.openInMemory());
      directory = Directory.systemTemp.createTempSync('kmreader-unit-');
      repository = Repository(
        profile: profile,
        store: store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: profile.authentication,
          credential: 'synthetic',
          client: MockClient((request) async {
            if (request.method == 'PATCH') {
              sent.add(jsonDecode(request.body)['page'] as int);
              return http.Response('', 204);
            }
            if (request.url.path.endsWith('/file')) {
              return http.Response.bytes([80, 75, 3, 4], 200);
            }
            if (request.url.path.contains('/pages/') ||
                request.url.path.endsWith('/thumbnail')) {
              return http.Response.bytes([1, 2, 3], 200);
            }
            return http.Response(
              jsonEncode({
                'content': [sampleBook().json],
                'last': true,
                'totalElements': 1,
              }),
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
    test('coalesces offline changes, retains read state, and sends only latest page', () async {
      repository.setOffline(true);
      repository.setProgress(sampleBook(), 2);
      repository.setProgress(sampleBook(), 4);
      expect(sent, isEmpty);
      expect(repository.pendingCount, 1);
      expect(repository.overlay(sampleBook()).page, 4);
      repository.offline = false;
      await repository.sync();
      expect(sent, [4]);
      expect(repository.pendingCount, 0);
    });
    test(
      'cached catalog can be browsed offline without losing local progress',
      () async {
        await repository.catalog('books');
        repository.setOffline(true);
        repository.setProgress(sampleBook(), 3);
        final result = await repository.catalog('books');
        expect(result.items.single.book.page, 3);
        await expectLater(
          repository.catalog('series'),
          throwsA(isA<ApiFailure>()),
        );
      },
    );
    test('download is marked ready only after original and every comic page are present', () async {
      await repository.download(sampleBook());
      expect(store.download(profile.id, 'book')!['status'], 'ready');
      expect(repository.bookFile(sampleBook()).existsSync(), isTrue);
      for (var page = 1; page <= 5; page++) {
        expect(repository.pageFile('book', page).existsSync(), isTrue);
      }
      repository.setOffline(true);
      expect(await repository.page('book', 5), [1, 2, 3]);
      await repository.removeDownload('book');
      expect(store.download(profile.id, 'book'), isNull);
    });
    test('failed synchronization keeps the durable outbox for retry', () async {
      repository.dispose();
      repository = Repository(
        profile: profile,
        store: store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: profile.authentication,
          credential: 'synthetic',
          client: MockClient((_) async => http.Response('', 503)),
        ),
      );
      repository.setOffline(true);
      repository.setProgress(sampleBook(), 2);
      repository.offline = false;
      await repository.sync();
      expect(repository.pendingCount, 1);
    });
  });
  group('Reader semantic position', () {
    test(
      'construction and layout changes emit no progress; rendered pages do',
      () {
        final commits = <int>[];
        final session = ReadingSession(
          count: 5,
          initialPage: 2,
          preferences: const ReaderPreferences(),
          onCommit: commits.add,
        );
        session.configure(
          session.preferences.copy(direction: ReadingDirection.rtl),
        );
        session.rendered(4);
        expect(commits, isEmpty);
        session.go(3);
        expect(commits, isEmpty);
        session.rendered(3);
        expect(commits, [3]);
        session.rendered(3);
        expect(commits, [3]);
        session.go(999);
        session.rendered(5);
        expect(commits, [3, 5]);
        session.dispose();
      },
    );
    test(
      'spread restoration retains focused page and commits its visible spread',
      () {
        final commits = <int>[];
        final session = ReadingSession(
          count: 5,
          initialPage: 2,
          preferences: const ReaderPreferences(spread: true),
          onCommit: commits.add,
        );
        expect(session.itemIndex, 0);
        session.rendered(1);
        expect(commits, isEmpty);
        session.go(3);
        session.rendered(3);
        expect(commits, [4]);
        session.next();
        session.rendered(5);
        expect(commits, [4, 5]);
        expect(session.atEnd, isTrue);
        session.dispose();
      },
    );
    test('incognito never emits progress, even at the final page', () {
      final commits = <int>[];
      final session = ReadingSession(
        count: 2,
        initialPage: 0,
        preferences: const ReaderPreferences(),
        onCommit: commits.add,
        incognito: true,
      );
      session.rendered(1);
      session.next();
      session.rendered(2);
      expect(commits, isEmpty);
      session.dispose();
    });
  });
}
