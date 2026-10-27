import 'dart:async';
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
  test('book and series sorts use their distinct upstream DTO fields', () {
    expect(sortQuery('books', 'metadata.titleSort,asc'), 'metadata.title,asc');
    expect(sortQuery('books', 'created,desc'), 'createdDate,desc');
    expect(sortQuery('books', 'lastModified,asc'), 'lastModifiedDate,asc');
    expect(sortQuery('series', 'created,desc'), 'created,desc');
    expect(
      sortQuery('series', 'metadata.titleSort,asc'),
      'metadata.titleSort,asc',
    );
    expect(
      sortFields('books', 'metadata.titleSort,asc'),
      sortFields('books', 'metadata.title,desc'),
    );
    expect(sortQuery('books', 'series,asc|metadata.numberSort,asc'), [
      'series,asc',
      'metadata.numberSort,asc',
    ]);
  });
  test('multi-column book sorting sends separate sort query values', () async {
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: 'synthetic',
      client: MockClient((request) async {
        expect(request.url.queryParametersAll['sort'], [
          'series,asc',
          'metadata.numberSort,asc',
        ]);
        return http.Response(
          jsonEncode({'content': [], 'last': true, 'totalElements': 0}),
          200,
        );
      }),
    );
    try {
      await api.catalog('books', sort: 'series,asc|metadata.numberSort,asc');
    } finally {
      api.close();
    }
  });
  test('task-queue SSE bursts do not reload catalogs; content bursts remain debounced', () async {
    final stream = StreamController<List<int>>();
    final directory = Directory.systemTemp.createTempSync('sse-catalog-');
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 's',
      name: 'Test',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    final repository = Repository(
      profile: profile,
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: Authentication.apiKey,
        credential: 'synthetic',
        client: MockClient.streaming(
          (request, _) async => http.StreamedResponse(stream.stream, 200),
        ),
      ),
    );
    try {
      repository.listen();
      for (var i = 0; i < 100; i++) {
        stream.add(utf8.encode('event: TaskQueueStatus\ndata: {}\n\n'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(repository.contentRevision, 0);
      for (var i = 0; i < 20; i++) {
        stream.add(utf8.encode('event: BookChanged\ndata: {}\n\n'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(repository.contentRevision, 1);
    } finally {
      repository.dispose();
      await stream.close();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
}
