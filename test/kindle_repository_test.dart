import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/conversion.dart';
import 'package:kmreader/core/kindle/library.dart';
import 'package:kmreader/core/kindle/positions.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/epub_fixture.dart';

void main() {
  final protocol = object(
    jsonDecode(
      File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
    ),
  );
  late Directory root;
  late LocalStore store;
  late KindleRepository repo;
  late Book book;
  late File publication;
  var position = 12;
  var time = '2020-01-01T00:00:00Z';
  var writes = 0;
  var confirm = true;
  var networkUnavailable = false;
  var expiredCdn = false, expiredRequests = 0;
  var edition = 'SYNTHETIC-ACR';
  late List<int> resource;
  late _Preparation preparation;
  var resourceRequests = 0;
  List<Json> annotations = [];
  Completer<void>? delayedSidecar, sidecarStarted;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('kindle-native-');
    store = LocalStore(sqlite3.open('${root.path}/store.sqlite'));
    final session = KindleSession({
      ...object(protocol['session']),
      'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
    });
    final profile = ServerProfile(
      id: session.id,
      name: 'Kindle',
      url: 'https://www.amazon.it',
      email: '',
      authentication: Authentication.apiKey,
      source: 'kindle',
    );
    position = 12;
    resourceRequests = 0;
    annotations = [];
    preparation = _Preparation();
    networkUnavailable = false;
    expiredCdn = false;
    expiredRequests = 0;
    delayedSidecar = null;
    sidecarStarted = null;
    writes = 0;
    confirm = true;
    edition = 'SYNTHETIC-ACR';
    time = '2020-01-01T00:00:00Z';
    publication = fixture(
      root,
      resources: {
        'META-INF/kmreader-kindle.json': utf8.encode(
          jsonEncode({
            'schema': 1,
            'position_units': 'unicode_scalars',
            'container_acrs': ['SYNTHETIC-ACR'],
            'entries': [
              {
                'path': 'OPS/one.xhtml',
                'id': 'text',
                'position': 10,
                'length': 200,
              },
            ],
          }),
        ),
      },
    );
    resource = publication.readAsBytesSync();
    store.cache(profile.id, 'kindle:catalog', {
      'items': [
        {
          'key': 'PDOC:opaque+/id',
          'id': 'opaque+/id',
          'type': 'PDOC',
          'title': 'Documento sintetico',
          'authors': ['Autore'],
        },
        {
          'key': 'PDOC:second',
          'id': 'second',
          'type': 'PDOC',
          'title': 'Secondo documento',
        },
        {
          'key': 'EBOK:dict',
          'id': 'dict',
          'type': 'EBOK',
          'title': 'Dictionary',
          'is_amazon_dictionary': true,
        },
      ],
    });
    final client = KindleClient(
      session: session,
      client: MockClient((request) async {
        if (request.url.path.endsWith('syncMetaData')) {
          return http.Response(
            '<response><add_update_list><meta_data><ASIN>opaque+/id</ASIN>'
            '<cde_contenttype>PDOC</cde_contenttype>'
            '<title>Documento sintetico</title></meta_data>'
            '</add_update_list></response>',
            200,
          );
        }
        if (request.url.path.endsWith('/sidecar')) {
          if (networkUnavailable) return http.Response('', 503);
          if (request.method == 'GET') {
            expect(request.url.queryParameters['guid'], isNotEmpty);
          }
          if (request.method == 'GET' &&
              request.url.queryParameters['key'] == 'opaque+/id' &&
              delayedSidecar != null) {
            sidecarStarted?.complete();
            await delayedSidecar!.future;
          }
          if (request.method == 'POST') {
            writes++;
            expect(request.url.queryParameters.keys, ['type']);
            expect(request.body, isNot(contains('furthest')));
            expect(request.body, isNot(contains('<lpr')));
            expect(request.body, contains('key="opaque+/id"'));
            if (confirm) {
              position = int.parse(
                RegExp('begin="(\\d+)"').firstMatch(request.body)![1]!,
              );
            }
          }
          return http.Response(
            jsonEncode({
              'payload': {
                'acr': edition,
                'guid': 'SYNTHETIC-GUID',
                'records': [
                  ...annotations,
                  {
                    'type': 'kindle.most_recent_read',
                    'location': position,
                    'creationTime': time,
                  },
                  {
                    'type': 'kindle.highlight',
                    'text': 'PRIVATE_NOTE_MUST_NOT_BE_CACHED',
                  },
                ],
              },
            }),
            200,
          );
        }
        if (request.url.host == 'kindle-digital-delivery.amazon.com') {
          return http.Response(
            jsonEncode({
              'resources': [
                {
                  'id': 'base',
                  if (expiredCdn)
                    'optimalEndpoint': {
                      'directUrl': 'https://expired.cloudfront.net/book',
                    },
                  'type': 'KINDLE_MAIN_BASE',
                  'requirement': 'REQUIRED',
                  'endpoint': {'url': 'https://fixture.cloudfront.net/book'},
                },
              ],
            }),
            200,
          );
        }
        if (request.url.host == 'expired.cloudfront.net') {
          expiredRequests++;
          return http.Response('', 403);
        }
        if (request.url.host == 'fixture.cloudfront.net') {
          expect(request.headers['x-adp-token'], isNull);
          resourceRequests++;
          return http.Response.bytes(resource, 200);
        }
        throw StateError('Unexpected test request');
      }),
    );
    repo = KindleRepository(
      profile: profile,
      store: store,
      directory: root,
      client: client,
      preparation: preparation,
    );
    book = await repo.book(repo.library.idFor(repo.library.items.first));
    store.setSetting('kindleMapped:${profile.id}:${book.id}', true);
  });
  tearDown(() {
    repo.dispose();
    store.close();
    root.deleteSync(recursive: true);
  });
  test(
    'confirmed cloud removal cannot reappear from a retained device catalog',
    () async {
      final raw = repo.library.item(book.id);
      store.recordProgress(repo.profile.id, book.id, {
        'page': 17,
        'completed': true,
      });
      await repo.download(book);
      repo.library.markCloudRemoved(text(raw['id']));
      await repo.library.refresh(full: true);
      expect(repo.library.items.any((item) => item['id'] == raw['id']), false);
      expect(await repo.bookFile(book).exists(), true);
      expect(store.progress(repo.profile.id, book.id)?['page'], 17);
      final reopened = KindleLibrary(
        profile: repo.profile,
        store: store,
        directory: root,
        client: KindleClient(
          session: repo.library.client.session,
          client: MockClient((request) async {
            fail('Offline reopening must not require a network request');
          }),
        ),
        preparation: preparation,
      );
      await reopened.ready;
      expect(reopened.items.any((item) => item['id'] == raw['id']), false);
      reopened.allowCloudDocument(text(raw['id']));
      expect(reopened.items.any((item) => item['id'] == raw['id']), true);
      reopened.close();
    },
  );
  test(
    'same catalog supports library search and hides Amazon dictionaries',
    () async {
      expect(repo.supportsSeries, false);
      expect(
        (await repo.catalog('books', search: 'sintetico')).items.single.id,
        book.id,
      );
      expect((await repo.catalog('books')).items, hasLength(2));
      store.setSetting('kindleDictionaries:${repo.profile.id}', true);
      await repo.library.index();
      expect((await repo.catalog('books')).items, hasLength(2));
    },
  );
  test(
    'resume uses exact edition and original position without storing note text',
    () async {
      final locator = await repo.externalDocumentPosition(book, publication);
      expect(locator?['href'], 'one.xhtml');
      expect(locator?['offset'], 2);
      expect(
        jsonEncode(store.cached(repo.profile.id, 'kindle:sidecar:${book.id}')),
        isNot(contains('PRIVATE_NOTE')),
      );
      edition = 'ANOTHER-EDITION';
      expect(await repo.externalDocumentPosition(book, publication), isNull);
    },
  );
  test('position outbox survives offline restart and verifies the write by reading back', () async {
    repo.setOffline(true);
    await repo.externalDocumentPosition(book, publication);
    repo.documentPosition(book, {'kindlePosition': 42});
    expect(repo.pendingCount, 1);
    await repo.sync(force: true);
    expect(writes, 0);
    final pending = object(store.cached(repo.profile.id, 'kindle:outbox'));
    expect(object(pending[book.id])['position'], 42);
    expect(store.cached('another-account', 'kindle:outbox'), isNull);
    store.setSetting('offline:${repo.profile.id}', false);
    // Recreate the source to exercise persisted state, not a memory-only queue.
    final reopened = LocalStore(sqlite3.open('${root.path}/store.sqlite'));
    expect(object(reopened.cached(repo.profile.id, 'kindle:outbox')), pending);
    reopened.close();
    repo.setOffline(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await repo.sync(force: true);
    expect(writes, 1);
    expect(position, 42);
    expect(repo.pendingCount, 0);
  });
  test('HTTP 200 without confirmed position retains the outbox', () async {
    await repo.externalDocumentPosition(book, publication);
    repo.documentPosition(book, {'kindlePosition': 42});
    confirm = false;
    await repo.sync(force: true);
    expect(repo.pendingCount, 1);
    expect(repo.syncFailure, contains('position_not_confirmed'));
  });
  test('newer remote progress conflicts and accepting server clears pending locator', () async {
    await repo.externalDocumentPosition(book, publication);
    repo.documentPosition(book, {'kindlePosition': 42});
    final pending = object(store.cached(repo.profile.id, 'kindle:outbox'));
    pending[book.id] = {...object(pending[book.id]), 'not_before': 0};
    store.cache(repo.profile.id, 'kindle:outbox', pending);
    position = 80;
    time = '2099-01-01T00:00:00Z';
    await repo.sync();
    expect(writes, 0);
    expect(repo.conflicts, contains(book.id));
    repo.acceptServerProgress();
    expect(repo.pendingCount, 0);
    expect(
      (await repo.externalDocumentPosition(book, publication))?['offset'],
      70,
    );
  });
  test(
    'edition changes never send pending progress to another publication',
    () async {
      await repo.externalDocumentPosition(book, publication);
      repo.documentPosition(book, {'kindlePosition': 42});
      edition = 'ANOTHER-EDITION';
      await repo.sync(force: true);
      expect(writes, 0);
      expect(repo.pendingCount, 1);
    },
  );
  test('the real pinned download queue completes without sending its completers to an isolate', () async {
    await repo.download(book);
    expect(store.download(repo.profile.id, book.id)?['status'], 'ready');
    expect(await repo.bookFile(book).readAsBytes(), resource);
    expect(preparation.calls, 1);
  });
  test(
    'opening then pinning reuses the prepared book and never converts twice',
    () async {
      final lease = await repo.documents.open(
        book,
        pinned: repo.bookFile(book),
        offline: false,
      );
      lease.close();
      final requests = resourceRequests;
      await repo.download(book);
      expect(preparation.calls, 1);
      expect(resourceRequests, requests);
      expect(store.download(repo.profile.id, book.id)?['status'], 'ready');
    },
  );
  test('Kindle imports only matching-edition annotations and replaces remote deletions', () async {
    annotations = [
      {
        'type': 'kindle.bookmark',
        'annotationId': 'synthetic-bookmark',
        'startPosition': '42',
      },
      {
        'type': 'kindle.highlight',
        'annotationId': 'synthetic-highlight',
        'startPosition': '50',
        'endPosition': '70',
      },
      {
        'type': 'kindle.note',
        'annotationId': 'synthetic-note',
        'startPosition': '80',
        'endPosition': '90',
        'noteText': 'Synthetic note',
      },
      {
        'type': 'kindle.bookmark',
        'annotationId': 'unmapped',
        'startPosition': '9000',
      },
    ];
    await repo.externalDocumentPosition(book, publication);
    final marks = repo.documentAnnotations(book);
    expect(marks, hasLength(3));
    expect(marks.first['locator']['offset'], 32);
    expect(marks[1]['endLocator']['offset'], 60);
    expect(marks.last['label'], 'Synthetic note');
    annotations = [];
    await repo.externalDocumentPosition(book, publication);
    expect(repo.documentAnnotations(book), isEmpty);
    annotations = [
      {
        'type': 'kindle.bookmark',
        'annotationId': 'wrong-edition',
        'startPosition': '42',
      },
    ];
    edition = 'OTHER-EDITION';
    await repo.externalDocumentPosition(book, publication);
    expect(repo.documentAnnotations(book), isEmpty);
  });
  test('native delivery prepares offline document and refreshes existing catalog metadata', () async {
    final lease = await repo.documents.open(
      book,
      pinned: repo.bookFile(book),
      offline: false,
    );
    addTearDown(lease.close);
    final target = lease.file;
    final cached = await repo.documents.open(
      book,
      pinned: repo.bookFile(book),
      offline: true,
    );
    expect(cached.file.path, target.path);
    cached.close();
    expect(await target.readAsBytes(), resource);
    expect((await repo.resolveDocumentBook(book, target)).format, 'epub');
    expect(
      store.setting<bool>('kindleMapped:${repo.profile.id}:${book.id}'),
      false,
    );
    expect(
      await Directory('${root.path}/${repo.profile.id}/kindle-staging')
          .list()
          .length,
      0,
    );
  });
  test(
    'original locators reject invalid timestamps and surrogate-unsafe guesses',
    () {
      expect(kindleTimestamp(double.nan), isNull);
      expect(
        kindleLastRead({
          'records': [
            {'type': 'kindle.most_recent_read', 'location': '12.4'},
          ],
        }),
        isNull,
      );
      final map = KindlePositionMap(
        [
          {'position': 10, 'length': 5, 'id': 'p'},
        ],
        {'edition'},
      );
      expect(map.locator(15), isNull);
      expect(map.locator(12)?['offset'], 2);
    },
  );
  test('indexed original positions retain the shortest overlapping span and reject gaps', () {
    final map = KindlePositionMap(
      [
        {'position': 15, 'length': 3, 'id': 'child'},
        {'position': 10, 'length': 100, 'id': 'parent'},
        {'position': 200, 'length': 5, 'id': 'next'},
      ],
      {'edition'},
    );
    expect(map.locator(16)?['id'], 'child');
    expect(map.locator(18)?['id'], 'parent');
    expect(map.locator(110), isNull);
    expect(map.locator(150), isNull);
    expect(map.locator(200)?['id'], 'next');
    expect(map.locator(205), isNull);
  });
  test(
    'expired CDN delivery falls back to the manifest alternate endpoint',
    () async {
      expiredCdn = true;
      final lease = await repo.documents.open(
        book,
        pinned: repo.bookFile(book),
        offline: false,
      );
      try {
        expect(expiredRequests, 1);
        expect(await lease.file.readAsBytes(), resource);
      } finally {
        lease.close();
      }
    },
  );
  test('late sidecar cannot replace the current reader mapping', () async {
    delayedSidecar = Completer<void>();
    sidecarStarted = Completer<void>();
    final previous = repo.externalDocumentPosition(book, publication);
    await sidecarStarted!.future;
    store.setSetting('kindleDictionaries:${repo.profile.id}', true);
    await repo.library.index();
    final current = await repo.book(
      repo.library.idFor(repo.library.items.last),
    );
    store.setSetting('kindleMapped:${repo.profile.id}:${current.id}', true);
    expect(
      await repo.externalDocumentPosition(current, publication),
      isNotNull,
    );
    delayedSidecar!.complete();
    expect(await previous, isNull);
    repo.documentPosition(current, {'kindlePosition': 42});
    expect(repo.pendingCount, 1);
  });
  test(
    'opening without network queues positions and synchronizes after reconnect',
    () async {
      networkUnavailable = true;
      expect(await repo.externalDocumentPosition(book, publication), isNull);
      repo.documentPosition(book, {'kindlePosition': 42});
      expect(repo.pendingCount, 1);
      await repo.sync(force: true);
      expect(writes, 0);
      expect(repo.pendingCount, 1);
      networkUnavailable = false;
      await repo.sync(force: true);
      expect(position, 42);
      expect(writes, 1);
      expect(repo.pendingCount, 0);
    },
  );
  test('Fiona GUID identifies the container when its ACR names another representation', () {
    final map = KindlePositionMap([], {'CONTAINER'});
    expect(
      map.matches({'guid': 'CONTAINER', 'acr': 'ANOTHER-REPRESENTATION'}),
      true,
    );
    expect(
      map.matches({'guid': 'DIFFERENT', 'acr': 'ANOTHER-REPRESENTATION'}),
      false,
    );
  });
}

class _Preparation implements KindlePreparation {
  int calls = 0;
  @override
  Future<Json> prepare(
    Directory directory, {
    Future<void>? abortTrigger,
  }) async {
    calls++;
    final receipt = object(
      jsonDecode(await File('${directory.path}/receipt.json').readAsString()),
    );
    final resource = object((receipt['resources'] as List).single);
    await File('${directory.path}/${resource['file']}')
        .copy('${directory.path}/ready.epub');
    return {
      'file': 'ready.epub',
      'format': 'epub',
      'kindle_locator_map': false,
    };
  }
}
