import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';

void main() {
  test('newer server progress is not overwritten without explicit conflict resolution', () async {
    final store = LocalStore(sqlite3.openInMemory());
    final directory = Directory.systemTemp.createTempSync('kmreader-conflict-');
    final book = Book({
      'id': 'book',
      'media': {'pagesCount': 5},
      'metadata': {'title': 'Test'},
    });
    final patches = <int>[];
    final repository = Repository(
      profile: const ServerProfile(
        id: 'server',
        name: 'Test',
        url: 'https://example.invalid',
        email: 'test@example.invalid',
        authentication: Authentication.password,
      ),
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.password,
        credential: 'synthetic',
        client: MockClient((request) async {
          if (request.method == 'PATCH') {
            patches.add(jsonDecode(request.body)['page'] as int);
            return http.Response('', 204);
          }
          return http.Response(
            jsonEncode({
              ...book.json,
              'readProgress': {
                'page': 5,
                'completed': true,
                'lastModified': '2099-01-01T00:00:00Z',
              },
            }),
            200,
          );
        }),
      ),
    );
    try {
      repository.setOffline(true);
      repository.setProgress(book, 2);
      repository.offline = false;
      await repository.sync();
      expect(patches, isEmpty);
      expect(repository.pendingCount, 1);
      expect(repository.conflicts, isNotEmpty);
      await repository.sync(force: true);
      expect(patches, [2]);
      expect(repository.pendingCount, 0);
      expect(repository.conflicts, isEmpty);
      repository.setOffline(true);
      repository.setProgress(book, 1);
      repository.offline = false;
      await repository.sync();
      repository.acceptServerProgress();
      expect(repository.overlay(book).page, 5);
      expect(repository.pendingCount, 0);
      expect(patches, [2]);
    } finally {
      repository.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
  test('binary requests negotiate binary data rather than JSON', () async {
    final client = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: 'synthetic',
      client: MockClient((request) async {
        expect(request.headers['Accept'], '*/*');
        return http.Response.bytes([137, 80, 78, 71], 200);
      }),
    );
    expect(await client.bytes('/api/v1/books/test/thumbnail'), [
      137,
      80,
      78,
      71,
    ]);
    client.close();
  });
}
