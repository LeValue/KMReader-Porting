import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/import.dart';
import 'package:kmreader/core/kindle/management.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_session.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';

import 'support/epub_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'confirmed',
    'lost_reply',
    'source_changed',
    'target_changed',
    'retire',
    'retire_lost_reply',
  ]) {
    test('replacement restores verified reading progress and completion: $mode', () async {
      final root = Directory.systemTemp.createTempSync('kindle-replacement-');
      final store = LocalStore(sqlite3.openInMemory());
      final protocol = object(
        jsonDecode(
          File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
        ),
      );
      final session = KindleSession({
        ...object(protocol['session']),
        'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
        'send_device': {
          'adp_token': object(protocol['session'])['adp_token'],
          'device_private_key': object(
            protocol['session'],
          )['device_private_key'],
        },
      });
      final profile = ServerProfile(
        id: session.id,
        name: 'Kindle',
        url: 'https://www.amazon.it',
        email: '',
        source: 'kindle',
        authentication: Authentication.apiKey,
      );
      const original = {
        'key': 'PDOC:OLD',
        'id': 'OLD',
        'type': 'PDOC',
        'title': 'Original',
        'revision': '1',
      };
      const target = {
        'key': 'PDOC:NEW',
        'id': 'NEW',
        'type': 'PDOC',
        'title': 'Updated',
        'revision': '1',
      };
      store.cache(profile.id, 'kindle:catalog', {
        'items': [original, target],
        'complete': true,
        'dictionary_filter_version': 1,
      });
      var uploads = 0, writes = 0, deletions = 0;
      var restored = false, uploaded = false, removed = false;
      var targetBookId = '';
      final client = KindleClient(
        session: session,
        client: MockClient((request) async {
          if (request.url.path.endsWith('syncMetaData')) {
            return http.Response(
              '<response><add_update_list>${removed ? '' : '<meta_data><ASIN>OLD</ASIN><cde_contenttype>PDOC</cde_contenttype><title>Original</title></meta_data>'}<meta_data><ASIN>NEW</ASIN><cde_contenttype>PDOC</cde_contenttype><title>Updated</title></meta_data></add_update_list></response>',
              200,
            );
          }
          if (request.url.path.endsWith('/sidecar') &&
              request.method == 'GET') {
            final old = request.url.queryParameters['key'] == 'OLD';
            final position = old
                ? (mode == 'source_changed' && uploaded ? 13 : 12)
                : restored
                ? 102
                : mode == 'target_changed'
                ? 101
                : 0;
            return http.Response(
              jsonEncode({
                'payload': {
                  'guid': old ? 'old' : 'new',
                  'records': [
                    {
                      'type': 'kindle.most_recent_read',
                      'location': position,
                      'creationTime': '2020-01-01T00:00:00Z',
                    },
                    if (old || restored)
                      {
                        'type': 'kindle.bookmark',
                        'annotationId': 'synthetic',
                        'startPosition': old ? '11' : '101',
                      },
                  ],
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/sidecar') &&
              request.method == 'POST') {
            writes++;
            final xml = XmlDocument.parse(request.body);
            expect(
              xml.findAllElements('book').single.getAttribute('key'),
              'NEW',
            );
            expect(
              xml.findAllElements('book').single.getAttribute('guid'),
              'new',
            );
            expect(
              xml.findAllElements('last_read').single.getAttribute('begin'),
              '102',
            );
            expect(
              xml.findAllElements('bookmark').single.getAttribute('begin'),
              '101',
            );
            restored = true;
            if (mode == 'lost_reply') {
              throw const SocketException('response lost');
            }
            return http.Response('', 200);
          }
          if (request.url.path.endsWith('upload-url')) {
            return http.Response(
              '{"statusCode":0,"stkToken":"test","uploadUrl":"https://zme-caps.amazon.com/asset"}',
              200,
            );
          }
          if (request.method == 'PUT') return http.Response('', 200);
          if (request.url.path.endsWith('send-to-kindle')) {
            uploads++;
            uploaded = true;
            return http.Response('{"statusCode":0,"sku":"NEW"}', 200);
          }
          if (mode.startsWith('retire')) {
            if (request.url.path.endsWith('/exchangetoken/cookies')) {
              return http.Response(
                jsonEncode({
                  'response': {
                    'tokens': {
                      'cookies': {
                        '.amazon.it': [
                          {'Name': 'session-id', 'Value': 'synthetic'},
                        ],
                      },
                    },
                  },
                }),
                200,
              );
            }
            if (request.url.path == '/hz/mycd/myx') {
              return http.Response('var csrfToken = "test";', 200);
            }
            if (request.url.path == '/hz/mycd/ajax') {
              deletions++;
              final data = object(jsonDecode(request.bodyFields['data']!));
              expect(
                object(
                  object(object(data['param'])['DeleteContent'])['asinDetails'],
                ).keys,
                ['OLD'],
              );
              expect(
                store.progress(profile.id, targetBookId)?['completed'],
                true,
              );
              removed = true;
              if (mode == 'retire_lost_reply') {
                throw const SocketException('lost delete response');
              }
              return http.Response('{}', 200);
            }
          }
          fail('No unscoped mutation or repeated upload is permitted');
        }),
      );
      final repo = KindleRepository(
        profile: profile,
        store: store,
        directory: root,
        client: client,
      );
      addTearDown(() async {
        await repo.stopDownloadWork();
        repo.dispose();
        store.close();
        await root.delete(recursive: true);
      });
      await repo.library.ready;
      final oldBook = await repo.book(repo.library.idFor(original));
      final newBook = await repo.book(repo.library.idFor(target));
      targetBookId = newBook.id;
      for (final pair in [(oldBook, 'old', 10), (newBook, 'new', 100)]) {
        final dir = Directory('${root.path}/${pair.$2}')..createSync();
        final publication = fixture(
          dir,
          resources: {
            'OPS/one.xhtml': utf8.encode(
              '<html><head><title>Test</title></head><body><p id="text">A🦆bc</p></body></html>',
            ),
            'META-INF/kmreader-kindle.json': utf8.encode(
              jsonEncode({
                'schema': 1,
                'position_units': 'unicode_scalars',
                'container_acrs': [pair.$2],
                'primary_acr': pair.$2,
                'entries': [
                  {
                    'path': 'OPS/one.xhtml',
                    'id': 'text',
                    'position': pair.$3,
                    'length': 4,
                  },
                ],
              }),
            ),
          },
        );
        final destination = repo.bookFile(pair.$1);
        await destination.parent.create(recursive: true);
        await publication.copy(destination.path);
        store.saveDownload(profile.id, pair.$1, 'ready');
      }
      store.recordProgress(profile.id, oldBook.id, {
        'page': 17,
        'completed': true,
        'readDate': '2020-01-01T00:00:00Z',
      });
      store.cache(profile.id, 'epub:${oldBook.id}', {
        'fontSize': 130,
        'cfi': 'epubcfi(/6/2!/4/2[text]/1:3)',
        'modified': '2019-01-01T00:00:00Z',
      });
      store.cache(profile.id, 'epubBookmarks:${oldBook.id}', [
        {'cfi': 'epubcfi(/6/2!/4/2[text]/1:3)', 'label': 'Local saved place'},
      ]);
      final manager = KindleDocumentManager(repo);
      await manager.sendUpdatedVersion(
        oldBook,
        XFile.fromData(Uint8List.fromList([1, 2, 3]), path: 'updated.txt'),
        title: 'Updated',
        author: 'Author',
        cancel: KindleImportCancellation(),
      );
      final operation = manager.operations.single;
      if (mode == 'source_changed' || mode == 'target_changed') {
        await expectLater(
          manager.restoreReplacement(text(operation['operation'])),
          throwsA(isA<KindleFailure>()),
        );
        expect(writes, 0);
        expect(store.progress(profile.id, newBook.id), isNull);
      } else {
        if (mode == 'lost_reply') {
          await expectLater(
            manager.restoreReplacement(text(operation['operation'])),
            throwsA(isA<KindleFailure>()),
          );
          expect(manager.operations.single['state'], 'migration_uncertain');
          expect(store.progress(profile.id, newBook.id), isNull);
        }
        await manager.restoreReplacement(text(operation['operation']));
        expect(manager.operations.single['state'], 'progress_restored');
        expect(writes, 1);
        expect(store.progress(profile.id, newBook.id)?['completed'], true);
        expect(
          store.progress(profile.id, newBook.id)?['readDate'],
          '2020-01-01T00:00:00Z',
        );
        final saved = object(store.cached(profile.id, 'epub:${newBook.id}'));
        expect(saved['fontSize'], 130);
        expect(object(saved['kindleResume'])['offset'], 2);
        final marks =
            store.cached(profile.id, 'epubBookmarks:${newBook.id}') as List;
        expect(object(marks.single)['kindlePosition'], 102);
        await manager.restoreReplacement(text(operation['operation']));
        expect(writes, 1);
        if (mode.startsWith('retire')) {
          if (mode == 'retire_lost_reply') {
            await expectLater(
              manager.retireReplacement(text(operation['operation'])),
              throwsA(isA<KindleFailure>()),
            );
            expect(
              manager.operations.single['state'],
              'replacement_retirement_uncertain',
            );
            expect(
              await manager.verifyDeletion(text(operation['operation'])),
              true,
            );
          } else {
            await manager.retireReplacement(text(operation['operation']));
          }
          expect(manager.operations.single['state'], 'done');
          expect(deletions, 1);
          expect(repo.library.items.any((i) => i['id'] == 'NEW'), true);
        }
      }
      if (mode == 'confirmed') {
        repo.setOffline(true);
        final session = await EpubSession.open(
          repo,
          await repo.book(newBook.id),
          repo.bookFile(newBook),
        );
        expect(
          object(session.configuration('test')['kindleResume'])['offset'],
          2,
        );
        await session.close();
      }
      expect(uploads, 1);
      expect(store.progress(profile.id, oldBook.id)?['page'], 17);
      expect(await repo.bookFile(oldBook).exists(), true);
    });
  }
  test(
    'failed local publication rolls back both SQLite and its progress overlay',
    () {
      final store = LocalStore(sqlite3.openInMemory());
      addTearDown(store.close);
      store.recordProgress('account', 'book', {'page': 8});
      expect(
        () => store.transaction(() {
          store.recordProgress('account', 'book', {'page': 0});
          store.cache('account', 'migration', {'state': 'done'});
          throw StateError('interrupted');
        }),
        throwsStateError,
      );
      expect(store.progress('account', 'book')?['page'], 8);
      expect(store.cached('account', 'migration'), isNull);
    },
  );
}
