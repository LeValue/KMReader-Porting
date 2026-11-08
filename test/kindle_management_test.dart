import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:kmreader/core/kindle/import.dart';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/document_edit.dart';
import 'package:kmreader/core/kindle/management.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_document.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/epub_fixture.dart';

void main() {
  test('edit reuses the downloaded personal source with its format and rejects purchases', () async {
    final root = Directory.systemTemp.createTempSync('kindle-edit-source-');
    final store = LocalStore(sqlite3.openInMemory());
    final protocol = object(
      jsonDecode(
        File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
      ),
    );
    final session = KindleSession({
      ...object(protocol['session']),
      'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
    });
    final profile = ServerProfile(
      id: session.id,
      name: 'Kindle',
      url: 'https://www.amazon.it',
      email: '',
      source: 'kindle',
      authentication: Authentication.apiKey,
    );
    const item = {
      'key': 'PDOC:SOURCE',
      'id': 'SOURCE',
      'type': 'PDOC',
      'title': 'Cached personal document',
      'revision': 'r1',
    };
    const purchase = {
      'key': 'EBOK:PURCHASE',
      'id': 'PURCHASE',
      'type': 'EBOK',
      'title': 'Purchased',
      'revision': 'r1',
    };
    store.cache(profile.id, 'kindle:catalog', {
      'items': [item, purchase],
      'complete': true,
      'dictionary_filter_version': 1,
    });
    final repo = KindleRepository(
      profile: profile,
      store: store,
      directory: root,
      client: KindleClient(
        session: session,
        client: MockClient((r) async {
          fail('A cached source must not require a network request');
        }),
      ),
    );
    addTearDown(() async {
      await repo.stopDownloadWork();
      repo.dispose();
      store.close();
      await root.delete(recursive: true);
    });
    await repo.library.ready;
    final book = Book(repo.library.bookJson(item));
    final source = repo.bookFile(book);
    await source.parent.create(recursive: true);
    await fixture(root).copy(source.path);
    store.saveDownload(profile.id, book, 'ready');
    final manager = KindleDocumentManager(repo);
    final selected = await manager.sourceForEdit(book);
    expect(selected.name, endsWith('.epub'));
    expect(selected.path, source.path);
    expect(await selected.readAsBytes(), await source.readAsBytes());
    await expectLater(
      manager.sourceForEdit(Book(repo.library.bookJson(purchase))),
      throwsA(
        isA<KindleFailure>().having(
          (e) => e.code,
          'code',
          'management_personal_only',
        ),
      ),
    );
  });

  test('EPUB edit preserves source, spine content and identity; installs a real cover', () async {
    final root = Directory.systemTemp.createTempSync('kindle-edit-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = fixture(root);
    final original = source.readAsBytesSync();
    final cover = File('${root.path}/cover.png')
      ..writeAsBytesSync(
        img.encodePng(
          img.Image(width: 20, height: 30)..clear(img.ColorRgb8(255, 0, 0)),
        ),
      );
    final target = '${root.path}/updated.epub';
    await editKindleEpub(
      source: source.path,
      target: target,
      title: 'Titolo & <nuovo>',
      author: 'Autore',
      cover: cover.path,
    );
    expect(source.readAsBytesSync(), original);
    final old = EpubDocument.open(source.path),
        updated = EpubDocument.open(target);
    addTearDown(old.close);
    addTearDown(updated.close);
    expect(updated.title, 'Titolo & <nuovo>');
    for (final chapter in old.chapters) {
      expect(updated.resource(chapter.path), old.resource(chapter.path));
    }
    final opf = utf8.decode(updated.resource('OPS/package.opf'));
    expect(opf, contains('550e8400-e29b-41d4-a716-446655440000'));
    expect(opf, contains('Autore'));
    expect(opf, contains('kmreader-cover'));
    final image = img.decodePng(updated.resource('OPS/kmreader-cover.png'))!;
    expect((image.width, image.height), (20, 30));
    final zip = ZipDecoder().decodeBytes(File(target).readAsBytesSync());
    expect(zip.first.name, 'mimetype');
    expect(zip.first.compression, CompressionType.none);
    await expectLater(
      editKindleEpub(
        source: source.path,
        target: source.path,
        title: 'No',
        author: '',
      ),
      throwsA(isA<KindleFailure>()),
    );
    expect(source.readAsBytesSync(), original);
  });

  test('invalid cover cannot leave a partially edited publication', () async {
    final root = Directory.systemTemp.createTempSync('kindle-edit-invalid-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = fixture(root),
        cover = File('${root.path}/bad.png')..writeAsStringSync('not an image');
    final target = '${root.path}/updated.epub';
    await expectLater(
      editKindleEpub(
        source: source.path,
        target: target,
        title: 'Title',
        author: '',
        cover: cover.path,
        summary: 'Descrizione aggiornata',
        language: 'it',
      ),
      throwsA(isA<KindleFailure>()),
    );
    expect(File(target).existsSync(), false);
    expect(File('$target.part').existsSync(), false);
  });

  test('UTF-16 package metadata is re-encoded with an accurate UTF-8 declaration', () async {
    final root = Directory.systemTemp.createTempSync('kindle-edit-encoding-');
    addTearDown(() => root.deleteSync(recursive: true));
    const opf =
        '<?xml version="1.0" encoding="UTF-16"?><package unique-identifier="uid"><metadata><identifier id="uid">same-id</identifier><title>Prima</title></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>';
    final source = fixture(
      root,
      paragraphCount: 2,
      resources: {
        'OPS/package.opf': [
          255,
          254,
          ...opf.codeUnits.expand((unit) => [unit & 255, unit >> 8]),
        ],
      },
    );
    final target = '${root.path}/updated.epub';
    await editKindleEpub(
      source: source.path,
      target: target,
      title: 'Nuovo titolo è 📚',
      author: 'Autore',
    );
    final document = EpubDocument.open(target);
    try {
      expect(document.title, 'Nuovo titolo è 📚');
      expect(
        utf8.decode(document.resource('OPS/package.opf')),
        contains('encoding="UTF-8"'),
      );
    } finally {
      document.close();
    }
  });

  for (final format in ['jpeg', 'svg+xml']) {
    test(
      'existing $format cover replacement preserves the original and enforces supported layouts',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'kindle-existing-cover-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final extension = format == 'jpeg' ? 'jpg' : 'svg';
        final source = fixture(
          root,
          paragraphCount: 2,
          resources: {
            'OPS/package.opf': utf8.encode(
              '<package version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">stable-id</dc:identifier><dc:title>Before</dc:title><meta name="cover" content="cover"/></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="oldcover.$extension" media-type="image/$format" properties="cover-image"/></manifest><spine><itemref idref="one"/></spine></package>',
            ),
            'OPS/oldcover.$extension': format == 'jpeg'
                ? img.encodeJpg(img.Image(width: 8, height: 12))
                : utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"/>'),
          },
        );
        final oldBytes = source.readAsBytesSync();
        final cover = File('${root.path}/new.png')
          ..writeAsBytesSync(img.encodePng(img.Image(width: 2500, height: 10)));
        final target = '${root.path}/updated.epub';
        final work = editKindleEpub(
          source: source.path,
          target: target,
          title: 'After',
          author: '',
          cover: cover.path,
        );
        if (format == 'jpeg') {
          await work;
          final document = EpubDocument.open(target);
          try {
            expect(
              img.decodeJpg(document.resource('OPS/oldcover.jpg'))!.width,
              2048,
            );
            expect(document.title, 'After');
          } finally {
            document.close();
          }
        } else {
          await expectLater(
            work,
            throwsA(
              isA<KindleFailure>().having(
                (e) => e.code,
                'code',
                'management_cover_layout',
              ),
            ),
          );
          expect(File(target).existsSync(), false);
        }
        expect(source.readAsBytesSync(), oldBytes);
      },
    );
  }

  test('updated copy journals all reading data and never retires the original without migration', () async {
    final root = Directory.systemTemp.createTempSync('kindle-version-');
    final store = LocalStore(sqlite3.openInMemory());
    final protocol = object(
      jsonDecode(
        File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
      ),
    );
    final data = object(protocol['session']);
    final session = KindleSession({
      ...data,
      'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
      'send_device': {
        'adp_token': data['adp_token'],
        'device_private_key': data['device_private_key'],
      },
    });
    final profile = ServerProfile(
      id: session.id,
      name: 'Kindle',
      url: 'https://www.amazon.it',
      email: '',
      authentication: Authentication.apiKey,
      source: 'kindle',
    );
    const item = {
      'key': 'PDOC:OLD',
      'id': 'OLD',
      'type': 'PDOC',
      'title': 'Old',
      'revision': 'r1',
    };
    store.cache(profile.id, 'kindle:catalog', {
      'items': [item],
      'complete': true,
      'dictionary_filter_version': 1,
    });
    var sends = 0, transfers = 0;
    final client = KindleClient(
      session: session,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/sidecar')) {
          return http.Response(
            jsonEncode({
              'payload': {
                'guid': 'old-edition',
                'records': [
                  {
                    'type': 'kindle.bookmark',
                    'annotationId': 'bookmark',
                    'startPosition': 42,
                  },
                  {'type': 'kindle.most_recent_read', 'location': 99},
                ],
              },
            }),
            200,
          );
        }
        if (request.url.path.endsWith('upload-url')) {
          return http.Response(
            '{"statusCode":0,"stkToken":"token","uploadUrl":"https://zme-caps.amazon.com/asset"}',
            200,
          );
        }
        if (request.method == 'PUT') {
          transfers++;
          expect(request.bodyBytes, [1, 2, 3]);
          return http.Response('', 200);
        }
        if (request.url.path.endsWith('send-to-kindle')) {
          sends++;
          return http.Response('{"statusCode":0,"sku":"NEW"}', 200);
        }
        fail(
          'An incomplete migration must not call another cloud mutation: ${request.url.path}',
        );
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
      store.close();
      root.deleteSync(recursive: true);
    });
    await repo.library.ready;
    final book = Book(repo.library.bookJson(item));
    store.cache(profile.id, 'epubBookmarks:${book.id}', [
      {'cfi': 'old-cfi', 'label': 'Local bookmark'},
    ]);
    store.recordProgress(profile.id, book.id, {'page': 9, 'completed': true});
    final manager = KindleDocumentManager(repo);
    final file = XFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      path: 'updated.txt',
    );
    expect(
      await manager.sendUpdatedVersion(
        book,
        file,
        title: 'Updated',
        author: 'Author',
        targets: ['device'],
        cancel: KindleImportCancellation(),
      ),
      'NEW',
    );
    final operation = manager.operations.single;
    expect(operation['new_id'], 'NEW');
    expect(operation['state'], 'replacement_migration_required');
    final backup = object(
      jsonDecode(
        File(
          '${root.path}/${profile.id}/kindle-management/${operation['backup']}',
        ).readAsStringSync(),
      ),
    );
    expect(backup['bookmarks'], hasLength(1));
    expect(object(backup['sidecar'])['records'], hasLength(2));
    expect(object(backup['progress'])['completed'], true);
    expect(store.progress(profile.id, book.id)?['page'], 9);
    await expectLater(
      manager.delete(book),
      throwsA(
        isA<KindleFailure>().having(
          (e) => e.code,
          'code',
          'management_pending',
        ),
      ),
    );
    expect((sends, transfers), (1, 1));
    expect(repo.library.item(book.id)['id'], 'OLD');
  });

  for (final mode in ['verify', 'lost_reply', 'auth_error']) {
    final loseReply = mode == 'lost_reply';
    test('remote PDOC deletion: $mode', () async {
      final root = Directory.systemTemp.createTempSync('kindle-management-');
      final store = LocalStore(sqlite3.openInMemory());
      final protocol = object(
        jsonDecode(
          File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
        ),
      );
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
      const item = {
        'key': 'PDOC:DOCUMENT',
        'id': 'DOCUMENT',
        'type': 'PDOC',
        'title': 'Personal document',
        'revision': 'r1',
      };
      const bought = {
        'key': 'EBOK:PURCHASE',
        'id': 'PURCHASE',
        'type': 'EBOK',
        'title': 'Purchased book',
        'revision': 'r1',
      };
      store.cache(profile.id, 'kindle:catalog', {
        'items': [item, bought],
        'complete': true,
        'dictionary_filter_version': 1,
      });
      var deletions = 0, removed = false;
      late KindleDocumentManager manager;
      final client = KindleClient(
        session: session,
        client: MockClient((request) async {
          expect(request.followRedirects, false);
          if (request.url.path.endsWith('/sidecar')) {
            expect(
              request.headers.keys.where(
                (key) => key.toLowerCase() == 'cookie',
              ),
              isEmpty,
            );
            return http.Response(
              jsonEncode({
                'payload': {
                  'guid': 'edition',
                  'records': [
                    {
                      'type': 'kindle.bookmark',
                      'annotationId': 'mark1',
                      'startPosition': 42,
                    },
                    {'type': 'kindle.most_recent_read', 'location': 99},
                  ],
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/exchangetoken/cookies')) {
            expect(
              request.bodyFields['source_token'],
              session.json['refresh_token'],
            );
            return http.Response(
              jsonEncode({
                'response': {
                  'tokens': {
                    'cookies': {
                      '.amazon.it': [
                        {'Name': 'session-id', 'Value': '"synthetic-cookie"'},
                      ],
                      '.evil.invalid': [
                        {'Name': 'bad', 'Value': 'never-send'},
                      ],
                    },
                  },
                },
              }),
              200,
            );
          }
          if (request.url.path == '/hz/mycd/myx') {
            expect(request.headers['cookie'], 'session-id=synthetic-cookie');
            return http.Response(
              '"csrfToken":"wrong-token";var csrfToken = "synthetic-csrf";',
              200,
              headers: {
                'set-cookie': 'session-id=renewed-cookie; Domain=.amazon.it; Path=/; Secure, bad=never-send; Domain=evil.invalid; Path=/',
              },
            );
          }
          if (request.url.path == '/hz/mycd/ajax') {
            expect(request.headers['cookie'], 'session-id=renewed-cookie');
            expect(request.headers['client'], 'MYX');
            expect(request.bodyFields['csrfToken'], 'synthetic-csrf');
            deletions++;
            expect(manager.operations.single['state'], 'delete_submitting');
            expect(
              object(
                object(
                  jsonDecode(
                    File(
                      '${root.path}/${profile.id}/kindle-management/${manager.operations.single['backup']}',
                    ).readAsStringSync(),
                  ),
                )['sidecar'],
              )['records'],
              hasLength(2),
            );
            final payload = object(jsonDecode(request.bodyFields['data']!));
            expect(
              object(
                object(
                  object(payload['param'])['DeleteContent'],
                )['asinDetails'],
              ),
              {
                'DOCUMENT': {'category': 'KindlePDoc'},
              },
            );
            expect(request.headers['cookie'], isNot(contains('never-send')));
            if (mode == 'auth_error') {
              return http.Response('{"error":"AUTHENTICATION_ERROR"}', 200);
            }
            if (loseReply) {
              removed = true;
              throw const SocketException('lost response');
            }
            return http.Response(
              '{}',
              200,
            ); // deliberately does NOT remove it yet
          }
          if (request.url.path.endsWith('/syncMetaData')) {
            return http.Response(
              '<response><add_update_list>${removed ? '' : '<meta_data><ASIN>DOCUMENT</ASIN><cde_contenttype>PDOC</cde_contenttype><title>Personal document</title></meta_data>'}</add_update_list></response>',
              200,
            );
          }
          fail('Unexpected request ${request.url.path}');
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
        store.close();
        root.deleteSync(recursive: true);
      });
      await repo.library.ready;
      manager = KindleDocumentManager(repo);
      final book = Book(repo.library.bookJson(item));
      final local = repo.bookFile(book);
      local.parent.createSync(recursive: true);
      local.writeAsStringSync('original retained');
      await expectLater(
        manager.delete(Book(repo.library.bookJson(bought))),
        throwsA(
          isA<KindleFailure>().having(
            (e) => e.code,
            'code',
            'management_personal_only',
          ),
        ),
      );
      expect(manager.operations, isEmpty);
      if (mode == 'auth_error') {
        await expectLater(
          manager.delete(book),
          throwsA(
            isA<KindleFailure>().having(
              (e) => e.code,
              'code',
              'management_authorization',
            ),
          ),
        );
        expect(manager.operations.single['state'], 'rejected');
        expect(manager.operations.single['server_rejected'], true);
        expect(deletions, 1);
        expect(repo.library.item(book.id)['id'], 'DOCUMENT');
        return;
      }
      if (loseReply) {
        await expectLater(manager.delete(book), throwsA(isA<KindleFailure>()));
        expect(manager.operations.single['state'], 'delete_uncertain');
      } else {
        await manager.delete(book);
        expect(manager.operations.single['state'], 'delete_verifying');
      }
      await expectLater(
        manager.delete(book),
        throwsA(
          isA<KindleFailure>().having(
            (e) => e.code,
            'code',
            'management_pending',
          ),
        ),
      );
      removed = true;
      final restarted = KindleDocumentManager(repo);
      expect(
        await restarted.verifyDeletion(
          text(manager.operations.single['operation']),
        ),
        true,
      );
      expect(restarted.operations.single['state'], 'done');
      expect(deletions, 1);
      expect(local.readAsStringSync(), 'original retained');
    });
  }
}
