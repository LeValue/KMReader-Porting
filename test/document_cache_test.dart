import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/document_cache.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

class _SmallCache extends DocumentCache {
  _SmallCache({
    required super.directory,
    required super.server,
    required super.store,
    required super.api,
  });
  @override
  int get budget => 20;
}

void main() {
  late Directory directory;
  late LocalStore store;
  late HttpServer server;
  late KomgaApi api;
  late DocumentCache cache;
  late int version, gets, heads;
  Future<void> Function(HttpRequest)? handler;
  final book = Book({
    'id': 'pdf',
    'media': {'mediaProfile': 'PDF'},
  });
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('document-cache-');
    store = LocalStore(sqlite3.open('${directory.path}/db.sqlite'));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api = KomgaApi(
      Uri.parse('http://127.0.0.1:${server.port}'),
      authentication: Authentication.apiKey,
      credential: 'fixture',
    );
    cache = _SmallCache(
      directory: Directory('${directory.path}/sources'),
      server: 's',
      store: store,
      api: api,
    );
    version = 1;
    gets = 0;
    heads = 0;
    handler = null;
    server.listen((request) async {
      if (handler != null) {
        await handler!(request);
        return;
      }
      request.response.headers.set('ETag', '"v$version"');
      if (request.method == 'HEAD') {
        heads++;
        if (request.headers.value('If-None-Match') == '"v$version"') {
          request.response.statusCode = 304;
        }
      } else {
        gets++;
        request.response.add([version, 2, 3]);
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    cache.close();
    api.close();
    store.close();
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });
  Future<DocumentLease> open({bool offline = false}) => cache.open(
    book,
    pinned: File('${directory.path}/pinned.pdf'),
    offline: offline,
  );

  test('concurrent document openings share one source and active readers survive cache clearing', () async {
    final leases = await Future.wait([open(), open()]);
    expect(gets, 1);
    expect(heads, 1);
    expect(leases[0].file.path, leases[1].file.path);
    await cache.trim(clear: true);
    expect(await leases.first.file.exists(), true);
    leases.first.close();
    await cache.trim(clear: true);
    expect(await leases.last.file.exists(), true);
    leases.last.close();
    await cache.trim(clear: true);
    expect(await leases.first.file.exists(), false);
    await expectLater(open(offline: true), throwsA(isA<ApiFailure>()));
  });
  test('conditional refresh prepares an immutable new version without changing an open document', () async {
    final original = await open();
    version = 2;
    await cache.revalidate(book);
    final updated = await open();
    expect(gets, 2);
    expect(original.file.path, isNot(updated.file.path));
    expect(await original.file.readAsBytes(), [1, 2, 3]);
    expect(await updated.file.readAsBytes(), [2, 2, 3]);
    await cache.revalidate(book);
    expect(gets, 2, reason: 'HTTP 304 must avoid downloading the body');
    original.close();
    updated.close();
  });
  test(
    'offline and pinned downloads never issue a validation request',
    () async {
      final first = await open();
      first.close();
      final offline = await open(offline: true);
      offline.close();
      expect(heads, 1);
      expect(gets, 1);
      final pinned = File('${directory.path}/pinned.pdf');
      await pinned.writeAsBytes([9]);
      store.saveDownload('s', book, 'ready');
      final permanent = await open();
      await cache.trim(clear: true);
      expect(permanent.file.path, pinned.path);
      expect(await pinned.readAsBytes(), [9]);
      expect(heads, 1);
      expect(gets, 1);
      permanent.close();
    },
  );
  test('another database connection waits for the source lease instead of writing the same partial', () async {
    final secondStore = LocalStore(sqlite3.open('${directory.path}/db.sqlite'));
    final secondApi = KomgaApi(
      Uri.parse('http://127.0.0.1:${server.port}'),
      authentication: Authentication.apiKey,
      credential: 'fixture',
    );
    final second = DocumentCache(
      directory: cache.directory,
      server: 's',
      store: secondStore,
      api: secondApi,
    );
    try {
      final leases = await Future.wait([
        open(),
        second.open(
          book,
          pinned: File('${directory.path}/pinned.pdf'),
          offline: false,
        ),
      ]);
      expect(gets, 1);
      expect(leases.first.file.path, leases.last.file.path);
      for (final lease in leases) {
        lease.close();
      }
      expect(store.accountTransferring('s'), false);
    } finally {
      second.close();
      secondApi.close();
      secondStore.close();
    }
  });
  test('legacy unpinned originals migrate into the disposable cache without network access offline', () async {
    final legacy = File('${directory.path}/pinned.pdf');
    await legacy.writeAsBytes([7, 8]);
    final lease = await open(offline: true);
    expect(lease.file.parent.path, cache.directory.path);
    expect(await legacy.exists(), false);
    expect(await lease.file.readAsBytes(), [7, 8]);
    expect(gets, 0);
    expect(heads, 0);
    lease.close();
    await cache.trim(clear: true);
    expect(await lease.file.exists(), false);
  });
  test('document quota evicts the least recently used source while protecting the open reader', () async {
    final lease = await open();
    final old = File('${cache.directory.path}/older.pdf');
    final recent = File('${cache.directory.path}/recent.pdf');
    await old.writeAsBytes(List.filled(14, 0));
    await old.setLastModified(DateTime(2020));
    await recent.writeAsBytes(List.filled(14, 0));
    await recent.setLastModified(DateTime(2024));
    await cache.trim();
    expect(await old.exists(), false);
    expect(await recent.exists(), true);
    expect(await lease.file.exists(), true);
    lease.close();
  });
  test('a failed source transfer resumes the persisted partial instead of accumulating orphan files', () async {
    var files = 0;
    handler = (request) async {
      request.response.headers.set('ETag', '"source-v1"');
      if (request.method == 'HEAD') {
        request.response.contentLength = 5;
        await request.response.close();
        return;
      }
      files++;
      if (request.headers.value('Range') == 'bytes=2-') {
        expect(request.headers.value('If-Range'), '"source-v1"');
        request.response.statusCode = 206;
        request.response.headers.set('Content-Range', 'bytes 2-4/5');
        request.response.contentLength = 3;
        request.response.add([3, 4, 5]);
        await request.response.close();
        return;
      }
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.add(
        'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nETag: "source-v1"\r\nConnection: close\r\n\r\n'
            .codeUnits,
      );
      socket.add([1, 2]);
      await socket.flush();
      await socket.close();
    };
    await expectLater(open(), throwsA(isA<Exception>()));
    final partials = cache.directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.part'))
        .toList();
    expect(partials, hasLength(1));
    expect(await partials.single.readAsBytes(), [1, 2]);
    final lease = await open();
    expect(files, 2);
    expect(await lease.file.readAsBytes(), [1, 2, 3, 4, 5]);
    expect(
      cache.directory.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.part'),
      ),
      isEmpty,
    );
    lease.close();
  });
}
