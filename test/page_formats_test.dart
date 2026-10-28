import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/page_formats.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';

void main() {
  final png = File('test/fixtures/page.png').readAsBytesSync();
  final tiff = File('test/fixtures/page.tiff').readAsBytesSync();
  final jp2 = File('test/fixtures/page.jp2').readAsBytesSync();
  late LocalStore store;
  late Directory directory;
  late Repository repository;
  final requests = <http.Request>[];
  setUp(() {
    store = LocalStore(sqlite3.openInMemory());
    directory = Directory.systemTemp.createTempSync('page-formats-');
    requests.clear();
    repository = Repository(
      profile: const ServerProfile(
        id: 's',
        name: 'Test',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.apiKey,
      ),
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.apiKey,
        credential: 'synthetic',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/pages')) {
            return http.Response(
              jsonEncode([
                {'number': 1, 'mediaType': 'image/tiff'},
              ]),
              200,
            );
          }
          if (request.url.path.endsWith('/file')) {
            return http.Response.bytes([80, 75, 3, 4], 200);
          }
          if (request.url.path.endsWith('/thumbnail')) {
            return http.Response.bytes(png, 200);
          }
          return http.Response.bytes(
            request.url.queryParameters['convert'] == 'png' ? png : tiff,
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
  test('retrying a comic page keeps portable conversion and bypasses stale converted bytes', () async {
    expect(await repository.page('book', 1), png);
    final before = requests
        .where((request) => request.url.queryParameters['convert'] == 'png')
        .length;
    expect(await repository.refreshPage('book', 1), png);
    expect(
      requests
          .where((request) => request.url.queryParameters['convert'] == 'png')
          .length,
      before + 1,
    );
    expect(portablePageBytes(await repository.page('book', 1)), true);
  });
  test(
    'portable image routing distinguishes TIFF and JPEG2000 from PNG/JPEG',
    () {
      expect(portablePageBytes(png), isTrue);
      expect(portablePageBytes(tiff), isFalse);
      expect(portablePageBytes(jp2), isFalse);
      expect(portablePageMediaType('image/jpeg'), isTrue);
      expect(portablePageMediaType('image/png'), isTrue);
      expect(portablePageMediaType('image/jp2'), isFalse);
      expect(portablePageMediaType('image/tiff'), isFalse);
    },
  );
  test('cold unsupported page conversion is coalesced, cached and never records reading progress', () async {
    final results = await Future.wait([
      repository.page('book', 1),
      repository.prefetchPage('book', 1),
    ]);
    expect(results, [png, png]);
    expect(requests.length, 2);
    expect(
      requests.where((r) => r.url.queryParameters['convert'] == 'png').length,
      1,
    );
    expect(await repository.page('book', 1), png);
    expect(requests.length, 2);
    expect(repository.pendingCount, 0);
    expect(
      await repository.cachedFile('/api/v1/books/book/pages/1').readAsBytes(),
      png,
    );
  });
  test('known page media type requests conversion directly without downloading the original page', () async {
    await repository.get('/api/v1/books/book/pages');
    expect(await repository.page('book', 1), png);
    expect(requests.length, 2);
    expect(requests.last.url.queryParameters['convert'], 'png');
  });
  test('legacy downloaded page is upgraded and survives clearing the temporary image cache', () async {
    final page = repository.pageFile('book', 1);
    await page.parent.create(recursive: true);
    await page.writeAsBytes(jp2);
    expect(await repository.page('book', 1), png);
    expect(await page.readAsBytes(), png);
    await repository.clearImageCache();
    repository.setOffline(true);
    expect(await repository.page('book', 1), png);
    expect(requests.length, 1);
    expect(repository.pendingCount, 0);
  });
  test('an offline unsupported legacy page is retained and asks for one conversion', () async {
    final page = repository.pageFile('book', 1);
    await page.parent.create(recursive: true);
    await page.writeAsBytes(tiff);
    repository.setOffline(true);
    await expectLater(
      repository.page('book', 1),
      throwsA(isA<ApiFailure>().having((e) => e.offline, 'offline', isTrue)),
    );
    expect(await page.readAsBytes(), tiff);
    expect(requests, isEmpty);
  });
  test('downloaded unsupported pages are already portable before a book becomes ready', () async {
    final book = Book({
      'id': 'book',
      'media': {'pagesCount': 1},
    });
    await repository.download(book);
    expect(store.download('s', 'book')!['status'], 'ready');
    expect(await repository.pageFile('book', 1).readAsBytes(), png);
    expect(requests.last.url.queryParameters['convert'], 'png');
    repository.setOffline(true);
    expect(await repository.page('book', 1), png);
  });
}
