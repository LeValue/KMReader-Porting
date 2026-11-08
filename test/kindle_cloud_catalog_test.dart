import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/management.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  for (final mode in [
    'complete',
    'incomplete',
    'duplicate',
    'foreign_category',
    'auth_error',
  ]) {
    test(
      'cloud ownership is account-scoped, PDOC-only and complete: $mode',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'kindle-cloud-catalog-',
        );
        final store = LocalStore(sqlite3.openInMemory());
        final session = KindleSession({
          ...object(
            object(
              jsonDecode(
                File('test/support/kindle_protocol_fixture.json')
                    .readAsStringSync(),
              ),
            )['session'],
          ),
          'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
        });
        var pages = 0;
        final client = KindleClient(
          session: session,
          client: MockClient((request) async {
            expect(request.followRedirects, false);
            if (request.url.path.endsWith('/exchangetoken/cookies')) {
              return http.Response(
                '{"response":{"tokens":{"cookies":{".amazon.it":[{"Name":"session-id","Value":"bound"}]}}}}',
                200,
              );
            }
            if (request.url.path == '/hz/mycd/myx') {
              return http.Response(
                'var csrfToken = "bound";',
                200,
                headers: {'set-cookie': 'session-id=; Max-Age=0; Path=/'},
              );
            }
            if (request.url.path == '/hz/mycd/ajax') {
              expect(request.headers['cookie'], 'session-id=bound');
              expect(request.headers['client'], 'MYX');
              final param = object(
                object(jsonDecode(request.bodyFields['data']!))['param'],
              );
              expect(param.keys, ['OwnershipData']);
              final query = object(param['OwnershipData']);
              expect(query['contentType'], 'KindlePDoc');
              expect(query['startIndex'], pages * 100);
              pages++;
              if (mode == 'auth_error') {
                return http.Response('{"error":"AUTHENTICATION_ERROR"}', 200);
              }
              final start = mode == 'duplicate' ? 0 : (pages - 1) * 100;
              final count = mode == 'complete' && pages == 2 ? 1 : 100;
              return http.Response(
                jsonEncode({
                  'OwnershipData': {
                    'items': [
                      for (var i = 0; i < count; i++)
                        {
                          'asin': 'Pdoc-${start + i}',
                          'category': mode == 'foreign_category'
                              ? 'KindleEBook'
                              : 'KindlePDoc',
                        },
                    ],
                    'numberOfItems': 101,
                    'hasMoreItems': mode == 'incomplete' ? false : pages == 1,
                  },
                }),
                200,
              );
            }
            fail(
              'Cloud inventory must not write documents, positions or device registration',
            );
          }),
        );
        final repo = KindleRepository(
          profile: ServerProfile(
            id: session.id,
            name: 'Cloud check',
            url: 'https://www.amazon.it',
            email: '',
            source: 'kindle',
            authentication: Authentication.apiKey,
          ),
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
        final manager = KindleDocumentManager(repo);
        if (mode == 'complete') {
          final cloud = await manager.cloudDocuments();
          expect(cloud['complete'], true);
          expect(cloud['items'] as List, hasLength(101));
          expect(pages, 2);
        } else {
          await expectLater(
            manager.cloudDocuments(),
            throwsA(isA<KindleFailure>()),
          );
        }
      },
    );
  }
}
