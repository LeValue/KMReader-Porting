import 'dart:convert';
import 'dart:io';

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
  for (final kind in ['books', 'series']) {
    test(
      '$kind restores an existing cover, removes only uploaded covers, refreshes its cache',
      () async {
        final directory = Directory.systemTemp.createTempSync('covers-test-');
        final store = LocalStore(sqlite3.openInMemory())
          ..setSetting('enableReadListSync', false);
        final requests = <http.Request>[];
        var selected = 'upload';
        var foreign = false;
        var removed = false;
        final owner = kind == 'books' ? 'bookId' : 'seriesId';
        final api = KomgaApi(
          Uri.parse('https://example.invalid/prefix'),
          authentication: Authentication.apiKey,
          credential: 'synthetic',
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('/thumbnails')) {
              return http.Response(
                jsonEncode([
                  {
                    'id': 'original',
                    owner: foreign ? 'other' : 'item',
                    'type': 'GENERATED',
                    'selected': selected == 'original',
                  },
                  if (!removed)
                    {
                      'id': 'upload',
                      owner: 'item',
                      'type': 'USER_UPLOADED',
                      'selected': selected == 'upload',
                    },
                ]),
                200,
              );
            }
            if (request.method == 'PUT') {
              selected = 'original';
              return http.Response('', 202);
            }
            if (request.method == 'DELETE') {
              removed = true;
              return http.Response('', 202);
            }
            return http.Response('{"seriesId":"parent"}', 200);
          }),
        );
        final repo = Repository(
          profile: const ServerProfile(
            id: 'fixture',
            name: 'Fixture',
            url: 'https://example.invalid/prefix',
            email: '',
            authentication: Authentication.apiKey,
            admin: true,
          ),
          api: api,
          store: store,
          directory: directory,
        );
        final admin = KomgaLibraryAdmin(repo);
        try {
          await admin.selectCover(kind, 'item', 'original');
          expect(selected, 'original');
          expect(
            requests.where((r) => r.method == 'PUT').single.url.path,
            '/prefix/api/v1/$kind/item/thumbnails/original/selected',
          );
          expect(
            repo.imageChanges.value,
            contains('/api/v1/$kind/item/thumbnail'),
          );
          if (kind == 'books') {
            expect(
              repo.imageChanges.value,
              contains('/api/v1/series/parent/thumbnail'),
            );
          }
          await admin.selectCover(kind, 'item', 'original');
          expect(requests.where((r) => r.method == 'PUT'), hasLength(1));
          await expectLater(
            admin.removeCover(kind, 'item', 'original'),
            throwsA(isA<ApiFailure>()),
          );
          expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
          await admin.removeCover(kind, 'item', 'upload');
          expect(removed, true);
          await admin.removeCover(kind, 'item', 'upload');
          expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
          expect(
            requests.where((r) => r.method == 'DELETE').single.url.path,
            '/prefix/api/v1/$kind/item/thumbnails/upload',
          );
          foreign = true;
          await expectLater(
            admin.selectCover(kind, 'item', 'original'),
            throwsA(isA<ApiFailure>()),
          );
          expect(requests.where((r) => r.method == 'PUT'), hasLength(1));
          repo.offline = true;
          final count = requests.length;
          await expectLater(
            admin.covers(kind, 'item'),
            throwsA(isA<ApiFailure>()),
          );
          expect(requests.length, count);
        } finally {
          repo.dispose();
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
}
