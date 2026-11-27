import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/catalog_tools.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/smart_lists.dart';
import 'package:kmreader/core/store.dart';

void main() {
  test('server filters preserve unknown conditions, role-specific authors and empty groups', () {
    for (final condition in <Json>[
      {
        'author': {
          'operator': 'is',
          'value': {'name': 'Author', 'role': 'writer'},
        },
      },
      {
        'futureField': {'operator': 'custom', 'value': 'something'},
      },
      {
        'releaseDate': {
          'operator': 'before',
          'dateTime': '2024-01-01T12:30:00Z',
        },
      },
      {'anyOf': <Json>[]},
      {
        'tag': {'operator': 'is', 'value': 'a', 'futureOption': true},
      },
    ]) {
      expect(
        CatalogFilter.fromCondition(condition, 'books').condition('books'),
        condition,
      );
    }
    final filter = {
      'allOf': [
        {
          'tag': {'operator': 'is', 'value': 'a'},
        },
        {
          'futureField': {'operator': 'custom'},
        },
      ],
    };
    expect(
      CatalogFilter.fromCondition(filter, 'books').condition('books'),
      filter,
    );
  });
  late Directory directory;
  late LocalStore store;
  late Repository repository;
  final requests = <http.Request>[];
  var missing = false;
  final original = <String, dynamic>{
    'id': 'smart',
    'ownerId': 'user',
    'name': 'Owned',
    'summary': '',
    'target': 'BOOK',
    'visibility': 'PRIVATE',
    'sharedWithUserIds': <String>[],
    'search': {
      'condition': {
        'author': {
          'operator': 'is',
          'value': {'name': 'Writer', 'role': 'writer'},
        },
      },
    },
  };
  setUp(() {
    missing = false;
    requests.clear();
    directory = Directory.systemTemp.createTempSync('smart-lists-');
    store = LocalStore(sqlite3.openInMemory());
    repository = Repository(
      profile: const ServerProfile(
        id: 's',
        name: 'Test',
        url: 'https://example.invalid',
        email: 'test@example.invalid',
        authentication: Authentication.apiKey,
        userId: 'user',
      ),
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.apiKey,
        credential: 'synthetic',
        client: MockClient((request) async {
          requests.add(request);
          if (missing) return http.Response('', 404);
          if (request.method == 'PATCH' || request.method == 'DELETE') {
            return http.Response('', 204);
          }
          if (request.url.path == '/api/v1/smart-lists/smart') {
            return http.Response(jsonEncode(original), 200);
          }
          return http.Response(
            jsonEncode({'content': [], 'last': true, 'totalElements': 0}),
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
  test('a saved smart list combines its own rules with offline search and account scope', () async {
    final service = SmartLists(repository);
    await service.get('smart');
    for (final (server, id, role) in [
      ('s', 'match', 'writer'),
      ('s', 'excluded', 'inker'),
      ('other', 'private', 'writer'),
    ]) {
      store.cache(server, 'book:$id', {
        'id': id,
        'name': 'Visible volume',
        'metadata': {
          'authors': [
            {'name': 'Writer', 'role': role},
          ],
        },
      });
    }
    repository.setOffline(true);
    final page = await repository.catalog(
      'books',
      path: '/api/v1/smart-lists/smart/books',
      search: 'volume',
      size: 1,
    );
    expect(page.items.map((item) => item.id), ['match']);
    expect(page.total, 1);
    repository.removeCatalogItem('smart-lists', 'smart');
    await expectLater(
      repository.catalog('books', path: '/api/v1/smart-lists/smart/books'),
      throwsA(isA<ApiFailure>()),
    );
  });
  test('Komga 404 is remembered for 24 hours without probing again', () async {
    missing = true;
    final service = SmartLists(repository);
    expect(await service.load(), isNull);
    expect(await service.load(), isNull);
    expect(requests.length, 1);
    repository.store.setSetting(
      'smartListsUnsupported:s',
      DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch,
    );
    expect(await service.load(), isNull);
    expect(requests.length, 2);
  });
  test('owner renaming omits stored search; admin-only sharing fields are rejected', () async {
    final service = SmartLists(repository);
    await service.save({'name': 'Renamed'}, original: original);
    expect(jsonDecode(requests.last.body), {'name': 'Renamed'});
    await expectLater(
      service.save({'visibility': 'PUBLIC'}, original: original),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
    );
    await expectLater(
      service.save(
        {'name': 'Other'},
        original: {...original, 'ownerId': 'other'},
      ),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
    );
    expect(requests.where((r) => r.method == 'PATCH').length, 1);
  });
  test('smart list content uses POST search body and sort, preserving server-side evaluation', () async {
    await repository.catalog(
      'books',
      path: '/api/v1/smart-lists/smart/books',
      search: 'word',
      condition: {
        'tag': {'operator': 'is', 'value': 'a'},
      },
      sort: 'metadata.numberSort,desc',
    );
    expect(requests.single.method, 'POST');
    expect(jsonDecode(requests.single.body), {
      'condition': {
        'tag': {'operator': 'is', 'value': 'a'},
      },
      'fullTextSearch': 'word',
    });
    expect(
      requests.single.url.queryParameters['sort'],
      'metadata.numberSort,desc',
    );
  });
}
