import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  for (final changed in [false, true]) {
    test(
      'expired media appears immediately and revalidates conditionally; changed=$changed',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'media-validators-',
        );
        final store = LocalStore(sqlite3.openInMemory());
        const profile = ServerProfile(
          id: 's',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        );
        var calls = 0;
        final validation = Completer<http.Response>(),
            validating = Completer<void>();
        final repository = Repository(
          profile: profile,
          directory: directory,
          store: store,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: Authentication.apiKey,
            credential: '',
            client: MockClient((request) async {
              calls++;
              if (calls == 1) {
                return http.Response.bytes([1], 200, headers: {'etag': '"v1"'});
              }
              expect(request.headers['If-None-Match'], '"v1"');
              validating.complete();
              return validation.future;
            }),
          ),
        );
        const path = '/api/v1/books/b/thumbnail';
        try {
          expect(await repository.image(path), [1]);
          store.db.execute('UPDATE image_versions SET validated=0');
          expect(
            await repository.image(path).timeout(const Duration(seconds: 1)),
            [1],
          );
          await validating.future;
          validation.complete(
            changed
                ? http.Response.bytes([2], 200, headers: {'etag': '"v2"'})
                : http.Response('', 304, headers: {'etag': '"v1"'}),
          );
          for (
            var i = 0;
            i < 200 &&
                (store.imageState(profile.id, path)['validated'] ?? 0) == 0;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(
            store.imageState(profile.id, path)['validated'],
            greaterThan(0),
          );
          expect(await repository.image(path), changed ? [2] : [1]);
          expect(calls, 2);
          expect(repository.imageChanges.value, changed ? {path} : isEmpty);
          expect(
            await repository.cachedFile(path).readAsBytes(),
            changed ? [2] : [1],
          );
          repository.setOffline(true);
          expect(await repository.image(path), changed ? [2] : [1]);
          expect(calls, 2);
        } finally {
          if (!validation.isCompleted) {
            validation.complete(http.Response('', 304));
          }
          await repository.stopDownloadWork();
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
}
