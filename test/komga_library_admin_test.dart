import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/komga_library_admin.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('destination rejects traversal, hidden files and unsupported formats before upload', () {
    KomgaLibraryAdmin.validateDestination('Serie Città', 'Volume 1.CBZ');
    KomgaLibraryAdmin.validateDestination('Publisher/Series', 'Volume 2.epub');
    for (final folder in ['../escape', r'a\b', '', '.hidden']) {
      expect(
        () => KomgaLibraryAdmin.validateDestination(folder, 'book.cbz'),
        throwsA(isA<ApiFailure>()),
      );
    }
    for (final name in [
      '../book.cbz',
      r'a\book.cbz',
      'book.exe',
      '.book.epub',
    ]) {
      expect(
        () => KomgaLibraryAdmin.validateDestination('Series', name),
        throwsA(isA<ApiFailure>()),
      );
    }
  });
  test('raw upload streams to the configured origin with auth, checksum and no redirect/retry', () async {
    final bytes = Uint8List.fromList(List.generate(10000, (i) => i % 256));
    var calls = 0, sent = 0;
    final api = KomgaApi(
      Uri.parse('https://example.invalid/komga'),
      authentication: Authentication.apiKey,
      credential: 'synthetic-key',
      client: MockClient.streaming((request, body) async {
        calls++;
        expect(request.url.path, '/komga/kmreader-admin/v1/uploads/id');
        expect(request.url.queryParameters['filename'], 'Città.cbz');
        expect(request.headers['X-API-Key'], 'synthetic-key');
        expect(request.headers['X-Content-SHA256'], 'a' * 64);
        expect(request.followRedirects, false);
        expect(request.contentLength, bytes.length);
        expect(await body.toBytes(), bytes);
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"status":"uploaded"}')),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final receipt = await api.uploadFile(
      '/kmreader-admin/v1/uploads/id',
      bytes: Stream.fromIterable([bytes.sublist(0, 4000), bytes.sublist(4000)]),
      length: bytes.length,
      progress: (value) => sent = value,
      query: {'filename': 'Città.cbz'},
      extra: {'X-Content-SHA256': 'a' * 64},
    );
    expect(receipt['status'], 'uploaded');
    expect(sent, bytes.length);
    expect(calls, 1);
    expect(() => api.uri('//outside.invalid/path'), throwsArgumentError);
  });

  test('cover multipart sends file and selected flag and a redirect never resubmits credentials', () async {
    var calls = 0;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.password,
      credential: 'synthetic-basic',
      client: MockClient.streaming((request, body) async {
        calls++;
        expect(request.method, 'POST');
        expect(request.url.queryParameters['selected'], 'true');
        expect(request.headers['Authorization'], 'Basic synthetic-basic');
        expect(
          request.headers['Content-Type'],
          startsWith('multipart/form-data; boundary='),
        );
        final payload = utf8.decode(await body.toBytes());
        expect(payload, contains('name="file"; filename="cover.png"'));
        expect(payload, contains('PNG-fixture'));
        return http.StreamedResponse(
          const Stream.empty(),
          307,
          headers: {'location': 'https://outside.invalid/'},
        );
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.uploadFile(
        '/api/v1/books/book/thumbnails',
        query: {'selected': true},
        bytes: Stream.value(utf8.encode('PNG-fixture')),
        length: 11,
        progress: (_) {},
        multipartFilename: 'cover.png',
      ),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 307)),
    );
    expect(calls, 1);
  });

  test('admin actions reject reader/offline/Kindle and deletion is only requested on Komga', () async {
    final directory = Directory.systemTemp.createTempSync('komga-admin-test-');
    final store = LocalStore(sqlite3.openInMemory());
    var calls = 0;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient((request) async {
        if (request.method != 'DELETE') return http.Response('[]', 200);
        calls++;
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/books/book/file');
        return http.Response('', 202);
      }),
    );
    Repository repo({bool admin = false, String source = 'komga'}) =>
        Repository(
          profile: ServerProfile(
            id: '$admin:$source',
            name: 'Fixture',
            url: 'https://example.invalid',
            email: '',
            authentication: Authentication.apiKey,
            admin: admin,
            source: source,
          ),
          api: api,
          directory: directory,
          store: store,
        );
    final reader = repo(),
        kindle = repo(admin: true, source: 'kindle'),
        admin = repo(admin: true);
    addTearDown(() {
      reader.dispose();
      kindle.dispose();
      admin.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    });
    await expectLater(
      KomgaLibraryAdmin(reader).deleteBook('book'),
      throwsA(isA<ApiFailure>()),
    );
    await expectLater(
      KomgaLibraryAdmin(kindle).deleteBook('book'),
      throwsA(isA<ApiFailure>()),
    );
    admin.setOffline(true);
    await expectLater(
      KomgaLibraryAdmin(admin).deleteBook('book'),
      throwsA(isA<ApiFailure>()),
    );
    expect(calls, 0);
    admin.setOffline(false);
    await KomgaLibraryAdmin(admin).deleteBook('book');
    expect(calls, 1);
  });

  test(
    'lost upload response is not retried and selected file digest is stable',
    () async {
      var calls = 0;
      final api = KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.apiKey,
        credential: '',
        client: MockClient.streaming((_, body) async {
          calls++;
          await body.drain<void>();
          throw http.ClientException('lost response');
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.uploadFile(
          '/kmreader-admin/v1/uploads/id',
          bytes: Stream.value([1, 2, 3]),
          length: 3,
          progress: (_) {},
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(calls, 1);
      final file = XFile.fromData(
        Uint8List.fromList(utf8.encode('abc')),
        name: 'book.cbz',
      );
      expect(
        await KomgaLibraryAdmin.digest(file),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    },
  );
}
