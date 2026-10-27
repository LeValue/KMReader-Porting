import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/cache.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_document.dart';

const profile = ServerProfile(
  id: 'perf',
  name: 'Test',
  url: 'https://example.invalid',
  email: '',
  authentication: Authentication.password,
);
Json page(String title) => {
  'content': [
    {
      'id': 'book',
      'metadata': {'title': title},
      'media': {'pagesCount': 10},
    },
  ],
  'last': true,
};

void main() {
  late Directory directory;
  late LocalStore store;
  Repository repo(Future<http.Response> Function(http.Request) handler) =>
      Repository(
        profile: profile,
        store: store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: Authentication.password,
          credential: '',
          client: MockClient(handler),
        ),
      );
  setUp(() {
    directory = Directory.systemTemp.createTempSync('kmreader-cache-');
    store = LocalStore(sqlite3.openInMemory());
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'weighted LRU preserves recently used bytes and respects its budget',
    () {
      final cache = WeightedCache<String, Uint8List>(
        maxWeight: 10,
        weight: (v) => v.length,
      );
      final a = Uint8List(4), b = Uint8List(4), c = Uint8List(4);
      cache.put('a', a);
      cache.put('b', b);
      expect(cache['a'], same(a));
      cache.put('c', c);
      expect(cache['b'], isNull);
      expect(cache['a'], same(a));
      cache.put('oversized', Uint8List(20));
      expect(cache['oversized'], isNull);
      expect(cache.currentWeight, 8);
    },
  );

  test('disk cache trims old media and clearing temporary images preserves downloads and progress', () async {
    final repository = repo((_) async => http.Response.bytes([1, 2, 3], 200));
    addTearDown(repository.dispose);
    await repository.imageDirectory.create(recursive: true);
    final old = File('${repository.imageDirectory.path}/old')
      ..writeAsBytesSync([1, 2, 3, 4]);
    old.setLastModifiedSync(DateTime(2000));
    final recent = File('${repository.imageDirectory.path}/recent')
      ..writeAsBytesSync([5, 6, 7, 8]);
    await trimMediaCache(repository.imageDirectory, 4);
    expect(old.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
    final book = Book({'id': 'download', 'name': 'download.pdf'});
    final source = repository.bookFile(book);
    await source.parent.create(recursive: true);
    await source.writeAsBytes([10, 20]);
    store.recordProgress(profile.id, book.id, {'page': 2});
    await repository.clearImageCache();
    expect(recent.existsSync(), isFalse);
    expect(source.readAsBytesSync(), [10, 20]);
    expect(store.pendingCount(profile.id), 1);
  });

  test('speculative images leave network slots for visible content and promote queued duplicates', () async {
    final queue = ImageRequests();
    final gates = List.generate(4, (_) => Completer<int>());
    final started = <int>[];
    Future<int> load(int i) {
      started.add(i);
      return gates[i].future;
    }

    final a = queue.run('a', () => load(0), speculative: true);
    final b = queue.run('b', () => load(1), speculative: true);
    expect(started, [0]);
    final foreground = queue.run('b', () => load(2));
    final visible = queue.run('c', () => load(3));
    expect(started, [0, 1, 3]);
    gates[0].complete(0);
    gates[1].complete(1);
    gates[3].complete(3);
    expect(await Future.wait([a, b, foreground, visible]), [0, 1, 1, 3]);
    queue.close();
  });

  test('concurrent cold catalog queries coalesce and warm navigation needs no HTTP', () async {
    var requests = 0;
    final gate = Completer<http.Response>();
    final repository = repo((_) {
      requests++;
      return gate.future;
    });
    addTearDown(repository.dispose);
    final first = repository.catalog('books');
    final second = repository.catalog('books');
    gate.complete(http.Response(jsonEncode(page('Cached book')), 200));
    expect((await first).items.single.title, 'Cached book');
    await second;
    final warm = await repository.catalog('books');
    expect(warm.items.single.title, 'Cached book');
    expect(requests, 1);
    final detail = await repository.book('book');
    expect(detail.title, 'Cached book');
    expect(
      requests,
      1,
      reason: 'A cached catalog item must open without a second metadata round trip',
    );
  });

  test('stale catalog returns immediately, revalidates once and publishes the fresh result', () async {
    var requests = 0;
    final gate = Completer<http.Response>();
    final freshEvent = Completer<void>();
    final refreshStarted = Completer<void>();
    final repository = repo((_) async {
      requests++;
      if (requests == 2) refreshStarted.complete();
      return requests == 1
          ? http.Response(jsonEncode(page('Old title')), 200)
          : gate.future;
    });
    addTearDown(repository.dispose);
    await repository.catalog('books');
    repository.catalogChanges.addListener(() {
      if (repository.cacheRevision > 0 && !freshEvent.isCompleted) {
        freshEvent.complete();
      }
    });
    repository.refreshContent();
    final cached = await repository.catalog('books');
    expect(cached.items.single.title, 'Old title');
    expect(gate.isCompleted, isFalse);
    await repository.catalog('books');
    await refreshStarted.future;
    expect(requests, 2);
    gate.complete(http.Response(jsonEncode(page('Fresh title')), 200));
    await freshEvent.future;
    expect(
      (await repository.catalog('books')).items.single.title,
      'Fresh title',
    );
    expect(requests, 2);
  });

  test('page prefetch shares bytes with visible pages, survives restart and never records progress', () async {
    var requests = 0;
    var repository = repo((_) async {
      requests++;
      return http.Response.bytes([137, 80, 78, 71], 200);
    });
    final prefetched = await repository.prefetchPage('book', 2);
    expect(await repository.page('book', 2), same(prefetched));
    expect(requests, 1);
    expect(repository.pendingCount, 0);
    repository.dispose();
    repository = repo(
      (_) async => throw StateError('Offline cache must not use HTTP'),
    )..setOffline(true);
    addTearDown(repository.dispose);
    expect(await repository.page('book', 2), prefetched);
    expect(repository.pendingCount, 0);
  });

  test('download notifications do not invalidate catalog widgets', () async {
    final repository = repo((_) async => http.Response('{}', 200));
    addTearDown(repository.dispose);
    var events = 0;
    repository.catalogChanges.addListener(() => events++);
    for (var i = 0; i < 100; i++) {
      repository.changed();
    }
    expect(events, 0);
    repository.refreshContent();
    expect(events, 1);
  });

  test('version-one cache data migrates without losing offline progress or metadata', () {
    final db = sqlite3.openInMemory();
    db.execute(
      'CREATE TABLE cache(server TEXT,key TEXT,value TEXT,PRIMARY KEY(server,key))',
    );
    db.execute('INSERT INTO cache VALUES(?,?,?)', [
      'old',
      'book',
      '{"title":"Preserved"}',
    ]);
    final migrated = LocalStore(db);
    try {
      expect(migrated.cached('old', 'book')['title'], 'Preserved');
      expect(migrated.cachedAt('old', 'book')!.millisecondsSinceEpoch, 0);
      migrated.recordProgress('old', 'book', {'page': 2});
      expect(migrated.pendingCount('old'), 1);
      expect(migrated.isPending('old', 'book'), isTrue);
      expect(migrated.progress('old', 'book')!['page'], 2);
    } finally {
      migrated.close();
    }
  });

  test('dashboard library scope uses Komga library_id and a small initial result set', () async {
    final repository = repo((request) async {
      expect(request.url.queryParameters['library_id'], 'library');
      expect(request.url.queryParameters['size'], '12');
      return http.Response(jsonEncode(page('Scoped')), 200);
    });
    addTearDown(repository.dispose);
    await repository.catalog(
      'books',
      path: '/api/v1/books/ondeck',
      libraryId: 'library',
      size: 12,
    );
  });

  test('EPUB indexing crosses an isolate boundary while retaining local resource access', () async {
    final document = await EpubDocument.openAsync('test/fixtures/sample.epub');
    try {
      expect(document.title, 'Synthetic EPUB');
      expect(document.chapters.length, 2);
      expect(document.chapter(1), contains('Second Chapter'));
    } finally {
      document.close();
    }
  });
}
