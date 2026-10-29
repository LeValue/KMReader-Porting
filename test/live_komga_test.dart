import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/server_event.dart';
import 'package:kmreader/core/server_management.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/core/catalog_tools.dart';
import 'package:kmreader/core/reading_stats.dart';
import 'package:kmreader/features/catalog/metadata_editor.dart';
import 'package:kmreader/features/catalog/dashboard.dart';
import 'package:kmreader/features/settings/library_editor.dart';
import 'package:kmreader/features/reader/epub_document.dart';

class _TransientVault implements CredentialVault {
  final _values = <String, String>{};
  @override
  Future<String?> read(String id) async => _values[id];
  @override
  Future<void> write(String id, String value) async {
    _values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    _values.remove(id);
  }
}

class _CountingClient extends http.BaseClient {
  final _inner = http.Client();
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

void main() {
  final url = Platform.environment['KMREADER_TEST_URL'];
  test(
    'real Komga: authentication, search, CBZ/EPUB/PDF download, offline progress and WebPub sync',
    () async {
      final directory = Directory.systemTemp.createTempSync('kmreader-client-');
      final store = LocalStore(sqlite3.open('${directory.path}/test.sqlite'));
      final client = _CountingClient();
      final api = KomgaApi(
        Uri.parse(url!),
        authentication: Authentication.password,
        client: client,
        credential: base64Encode(
          utf8.encode(
            '${Platform.environment['KMREADER_TEST_EMAIL']}:${Platform.environment['KMREADER_TEST_PASSWORD']}',
          ),
        ),
      );
      final user = await api.user();
      expect(user['email'], Platform.environment['KMREADER_TEST_EMAIL']);
      final profile = ServerProfile(
        id: ServerProfile.identity(Uri.parse(url), user['id']),
        name: 'Test',
        url: url,
        email: user['email'],
        authentication: Authentication.password,
        admin: true,
      );
      final repository = Repository(
        profile: profile,
        api: api,
        store: store,
        directory: directory,
      );
      try {
        final management = ServerManagement(repository);
        expect(await management.scheduledTasks(), isNotEmpty);
        expect((await management.sessions()).ownOnly, true);
        await management.taskMetrics();
        expect(await repository.komf.checkIntegration(), isNull);
        expect(
          object(
            await repository.get(
              '/api/v2/users/me/authentication-activity',
              query: {'page': 0, 'size': 20},
            ),
          )['content'],
          isA<List>(),
        );
        expect(
          (await repository.catalog(
            'books',
            path: '/api/v1/books/duplicates',
          )).total,
          0,
        );
        final cold = Stopwatch()..start();
        final books = await repository.catalog('books');
        cold.stop();
        expect(books.total, 3);
        final requestsBeforeWarm = client.requests;
        final warmTimes = <int>[];
        for (var i = 0; i < 20; i++) {
          final watch = Stopwatch()..start();
          expect((await repository.catalog('books')).total, books.total);
          warmTimes.add(watch.elapsedMicroseconds);
        }
        expect(
          client.requests,
          requestsBeforeWarm,
          reason:
              'Twenty warm catalog visits must avoid twenty HTTP round trips',
        );
        warmTimes.sort();
        stdout.writeln(
          'Real Komga loopback cache probe: cold=${cold.elapsedMicroseconds}us, warm median=${warmTimes[10]}us, 20 repeat visits / 0 extra HTTP requests. Not a phone FPS benchmark.',
        );
        final search = await repository.catalog(
          'books',
          search: 'Synthetic Comic',
        );
        expect(search.items.length, 1);
        final comic = search.items.single.book;
        expect(comic.pages, 3);
        final pageMetadata = (await api.request(
          '/api/v1/books/${comic.id}/pages',
        ) as List).map(object).toList();
        expect(text(pageMetadata[1]['mediaType']), contains('tiff'));
        expect(
          text(pageMetadata[2]['mediaType']),
          anyOf(contains('jp2'), contains('jpeg2000')),
        );
        final series = await repository.catalog('series');
        expect(series.items, isNotEmpty);
        final children = await repository.catalog(
          'books',
          condition: {
            'seriesId': {'operator': 'is', 'value': comic.seriesId},
          },
        );
        expect(children.items.any((v) => v.id == comic.id), isTrue);
        await repository.download(comic);
        expect(store.download(profile.id, comic.id)!['status'], 'ready');
        repository.setOffline(true);
        expect((await repository.page(comic.id, 3)).take(4), [137, 80, 78, 71]);
        for (final entry in {
          2: [0, 255, 0, 255],
          3: [0, 0, 255, 255],
        }.entries) {
          final bytes = await repository.page(comic.id, entry.key);
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          final pixels = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(pixels!.buffer.asUint8List().take(4), entry.value);
          frame.image.dispose();
          codec.dispose();
        }
        repository.setProgress(comic, 2);
        expect(repository.pendingCount, 1);
        expect((await repository.book(comic.id)).page, 2);
        repository.offline = false;
        await repository.sync();
        expect(repository.pendingCount, 0);
        expect((await api.book(comic.id)).page, 2);
        final continuing = DashboardQuery(
          'dashboard.keepReading',
          libraryId: comic.libraryId,
        );
        final continuingPage = await repository.catalog(
          continuing.kind,
          condition: continuing.condition,
          sort: continuing.sort,
          size: 12,
          force: true,
        );
        expect(continuingPage.items.map((item) => item.id), contains(comic.id));
        final released = DashboardQuery(
          'dashboard.recentlyReleasedBooks',
          libraryId: comic.libraryId,
        );
        await repository.catalog(
          released.kind,
          condition: released.condition,
          sort: released.sort,
          size: 12,
          force: true,
        );
        final read = DashboardQuery(
          'dashboard.recentlyReadBooks',
          libraryId: comic.libraryId,
        );
        final readPage = await repository.catalog(
          read.kind,
          condition: read.condition,
          sort: read.sort,
          size: 12,
          force: true,
        );
        expect(
          readPage.items.map((item) => item.id),
          isNot(contains(comic.id)),
        );
        final scoped = await repository.catalog(
          'books',
          condition: {
            'allOf': [
              {
                'libraryId': {'operator': 'is', 'value': comic.libraryId},
              },
              {
                'readStatus': {'operator': 'is', 'value': 'IN_PROGRESS'},
              },
            ],
          },
          size: 12,
        );
        expect(scoped.items.map((item) => item.id), contains(comic.id));
        repository.setOffline(true);
        repository.setProgress(comic, 0, reset: true);
        repository.offline = false;
        await repository.sync();
        expect((await api.book(comic.id)).page, 0);
        final epub = books.items
            .map((v) => v.book)
            .firstWhere((v) => v.format == 'epub');
        await repository.download(epub);
        final document = EpubDocument.open(repository.bookFile(epub).path);
        expect(document.chapters.length, 2);
        expect(document.chapter(1), contains('Second Chapter'));
        document.close();
        final manifest = object(
          await api.request(
            '/api/v1/books/${epub.id}/manifest',
            extra: {'Accept': 'application/webpub+json'},
          ),
        );
        final href = text(
          object((manifest['readingOrder'] as List).first)['href'],
        );
        repository.setOffline(true);
        repository.setEpubProgress(epub, href, .2, .1);
        repository.offline = false;
        await repository.sync();
        expect(repository.pendingCount, 0, reason: repository.syncFailure);
        final progression = object(
          await api.request(
            '/api/v1/books/${epub.id}/progression',
            extra: {'Accept': 'application/vnd.readium.progression+json'},
          ),
        );
        expect(
          href.endsWith(text(object(progression['locator'])['href'])),
          isTrue,
        );
        final pdf = books.items
            .map((v) => v.book)
            .firstWhere((v) => v.format == 'pdf');
        final cachedPdf = await repository.documents.open(
          pdf,
          pinned: repository.bookFile(pdf),
          offline: false,
        );
        expect(cachedPdf.file.readAsStringSync().startsWith('%PDF-'), isTrue);
        await repository.documents.revalidate(pdf);
        cachedPdf.close();
        await repository.download(pdf);
        expect(
          repository.bookFile(pdf).readAsStringSync().startsWith('%PDF-'),
          isTrue,
        );
        expect(
          store
              .downloads(profile.id)
              .where((v) => v['status'] == 'ready')
              .length,
          3,
        );
        final list = object(
          await api.request(
            '/api/v1/readlists',
            method: 'POST',
            body: {
              'name': 'Reading order',
              'summary': '',
              'ordered': true,
              'bookIds': [comic.id, pdf.id],
            },
          ),
        );
        final ordered = await repository.catalog(
          'books',
          path: '/api/v1/readlists/${list['id']}/books',
        );
        expect(ordered.items.map((v) => v.id), [comic.id, pdf.id]);
        final next = object(
          await api.request(
            '/api/v1/readlists/${list['id']}/books/${comic.id}/next',
          ),
        );
        expect(next['id'], pdf.id);
        final tools = CatalogTools(repository);
        final metadata = metadataPatch(
          'books',
          comic.metadata,
          {
            'tags': ['Porting Test'],
            'tagsLock': true,
          },
          {'tags', 'tagsLock'},
        );
        await tools.updateMetadata('books', comic.id, metadata);
        final edited = await api.book(comic.id);
        expect(edited.metadata['tags'], ['porting test']);
        expect(edited.metadata['tagsLock'], isTrue);
        final nested = CatalogFilter(
          entries: [
            {'field': 'tag', 'operator': 'is', 'value': 'Porting Test'},
            {
              'any': true,
              'entries': [
                {'field': 'title', 'operator': 'contains', 'value': 'Comic'},
                {'field': 'oneShot', 'operator': 'isTrue'},
              ],
            },
          ],
        );
        final filtered = await repository.catalog(
          'books',
          condition: nested.condition('books'),
          force: true,
        );
        expect(filtered.items.map((b) => b.id), [comic.id]);
        await tools.updateList('readlists', text(list['id']), list, {
          'name': 'Edited order',
          'bookIds': [pdf.id, comic.id],
        });
        final reordered = await repository.catalog(
          'books',
          path: '/api/v1/readlists/${list['id']}/books',
          force: true,
        );
        expect(reordered.items.map((b) => b.id), [pdf.id, comic.id]);
        repository.setOffline(true);
        repository.markBooks([comic], true);
        repository.offline = false;
        await repository.sync(force: true);
        expect(repository.pendingCount, 0, reason: repository.syncFailure);
        final readOnly = await repository.catalog(
          'books',
          path: '/api/v1/readlists/${list['id']}/books',
          condition: {
            'readStatus': {'operator': 'is', 'value': 'READ'},
          },
          force: true,
        );
        expect(readOnly.items.map((b) => b.id), [comic.id]);
        await repository.readLists.setEnabled(true);
        await repository.readLists.record(text(list['id']), comic.id);
        await repository.readLists.sync();
        expect(repository.readLists.error, isNull);
        final settings = object(
          await api.request('/api/v1/client-settings/user/list'),
        );
        final settingKey =
            'kmreader.readlist.${text(list['id']).toLowerCase()}';
        expect(
          jsonDecode(text(object(settings[settingKey])['value']))['bookId'],
          comic.id,
        );
        await repository.readLists.stop(text(list['id']));
        expect(
          object(await api.request('/api/v1/client-settings/user/list'))
              .containsKey(settingKey),
          false,
        );
        await repository.readLists.setEnabled(false);
        await repository.prepareOfflineCatalog();
        expect(repository.metadataIndexError, isNull);
        expect(store.offlineCatalog.count(profile.id, 'books'), 3);
        repository.setOffline(true);
        final localSearch = await repository.catalog(
          'books',
          search: 'Synthetic',
        );
        expect(localSearch.total, 3);
        final localList = await repository.catalog(
          'books',
          path: '/api/v1/readlists/${list['id']}/books',
        );
        expect(localList.items.map((b) => b.id), [pdf.id, comic.id]);
        repository.setOffline(false);
        final stats = await ReadingStats(repository).load();
        expect(stats['source'], 'local');
        expect(object(stats['summary'])['totalBooks'], 3);
        expect(
          object(stats['summary'])['booksCompletedReading'],
          greaterThanOrEqualTo(1),
        );
        final collection = object(
          await api.request(
            '/api/v1/collections',
            method: 'POST',
            body: {
              'name': 'Collection Test',
              'ordered': true,
              'seriesIds': [comic.seriesId],
            },
          ),
        );
        await tools.updateList(
          'collections',
          text(collection['id']),
          collection,
          {'name': 'Edited Collection'},
        );
        expect(
          (await tools.list('collections', text(collection['id'])))['name'],
          'Edited Collection',
        );
        await tools.deleteList('collections', text(collection['id']));
        final emptyFolder = await Directory('${directory.path}/empty-library')
            .create();
        final sseResponse = await api.send(
          '/sse/v1/events',
          extra: {'Accept': 'text/event-stream'},
        );
        final libraryEvent = decodeServerEvents(sseResponse.stream)
            .firstWhere((event) => event.type == 'LibraryAdded')
            .timeout(const Duration(seconds: 15));
        final newLibrary = object(
          await api.request(
            '/api/v1/libraries',
            method: 'POST',
            body: libraryPatch(
              defaultLibrary()..addAll({
                'name': 'Editor Test',
                'root': emptyFolder.path,
                'scanInterval': 'DISABLED',
              }),
              null,
            ),
          ),
        );
        expect((await libraryEvent).object?['libraryId'], newLibrary['id']);
        await api.request(
          '/api/v1/libraries/${newLibrary['id']}',
          method: 'PATCH',
          body: libraryPatch({
            ...newLibrary,
            'name': 'Edited Library',
          }, newLibrary),
        );
        expect(
          object(
            await api.request('/api/v1/libraries/${newLibrary['id']}'),
          )['name'],
          'Edited Library',
        );
        await api.request(
          '/api/v1/libraries/${newLibrary['id']}',
          method: 'DELETE',
        );
        final events = object(
          await api.request(
            '/api/v1/history',
            query: {'size': 10, 'sort': 'timestamp,desc'},
          ),
        );
        expect(events['content'], isA<List>());
        await tools.deleteList('readlists', text(list['id']));
        final key = object(
          await api.request(
            '/api/v2/users/me/api-keys',
            method: 'POST',
            body: {'comment': 'Synthetic integration test'},
          ),
        );
        final keyApi = KomgaApi(
          Uri.parse(url),
          authentication: Authentication.apiKey,
          credential: text(key['key']),
        );
        try {
          expect((await keyApi.user())['id'], user['id']);
          await api.request(
            '/api/v2/users/me/api-keys/${key['id']}',
            method: 'DELETE',
          );
          await expectLater(
            keyApi.user(),
            throwsA(
              isA<ApiFailure>().having((e) => e.status, 'revoked status', 401),
            ),
          );
        } finally {
          keyApi.close();
        }
        // Mutate only this disposable instance, then restore its generated
        // fixture password. Exercise the real account/vault/reconnect flow.
        final vault = _TransientVault();
        final originalPassword =
            Platform.environment['KMREADER_TEST_PASSWORD']!;
        store.saveServer(profile);
        await vault.write(
          profile.id,
          base64Encode(utf8.encode('${profile.email}:$originalPassword')),
        );
        final account = AppController(
          store: store,
          directory: directory,
          vault: vault,
        )..repository = repository;
        try {
          await account.changePassword(repository, '$originalPassword-updated');
          expect((await account.repository!.api.user())['id'], user['id']);
          await account.changePassword(account.repository!, originalPassword);
          expect((await account.repository!.api.user())['id'], user['id']);
          expect(
            await vault.read(profile.id),
            base64Encode(utf8.encode('${profile.email}:$originalPassword')),
          );
        } finally {
          await account.repository?.stopDownloadWork();
          account.disconnect();
          account.dispose();
        }
      } on ApiFailure catch (e, stack) {
        fail('Komga HTTP ${e.status} at ${e.path}: ${e.message}\n$stack');
      } finally {
        repository.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
    skip: url == null
        ? 'Run python3 tool/komga_smoke.py --jar <official Komga 1.29.1 jar>'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
