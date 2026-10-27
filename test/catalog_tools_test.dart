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
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/metadata_editor.dart';

void main() {
  test(
    'nested filters encode typed Komga operators and reject invalid input',
    () {
      final filter = CatalogFilter(
        entries: [
          {'field': 'oneShot', 'operator': 'isFalse'},
          {
            'any': true,
            'entries': [
              {'field': 'author', 'operator': 'is', 'value': 'Author'},
              {
                'field': 'numberSort',
                'operator': 'greaterThan',
                'value': '1.5',
              },
            ],
          },
          {'field': 'releaseDate', 'operator': 'before', 'value': '2024-02-29'},
        ],
      );
      expect(filter.condition('books'), {
        'allOf': [
          {
            'oneShot': {'operator': 'isFalse'},
          },
          {
            'anyOf': [
              {
                'author': {
                  'operator': 'is',
                  'value': {'name': 'Author'},
                },
              },
              {
                'numberSort': {'operator': 'greaterThan', 'value': 1.5},
              },
            ],
          },
          {
            'releaseDate': {
              'operator': 'before',
              'dateTime': '2024-02-29T00:00:00.000Z',
            },
          },
        ],
      });
      for (final row in [
        {'field': 'releaseDate', 'operator': 'before', 'value': '2023-02-29'},
        {'field': 'numberSort', 'operator': 'is', 'value': 'NaN'},
        {'field': 'mediaStatus', 'operator': 'is', 'value': 'bad'},
        {'field': 'title', 'operator': 'isTrue'},
      ]) {
        expect(
          () => CatalogFilter(entries: [row]).condition('books'),
          throwsFormatException,
        );
      }
      expect(
        () => CatalogFilter(
          entries: [
            {'field': 'ageRating', 'operator': 'is', 'value': '1.5'},
          ],
        ).condition('series'),
        throwsFormatException,
      );
    },
  );
  test(
    'metadata changes preserve untouched fields and encode clearing and locks',
    () {
      final original = {
        'title': 'Old',
        'summary': 'Keep',
        'numberSort': 2,
        'tags': ['old'],
      };
      final values = {
        'title': 'New',
        'titleLock': true,
        'numberSort': '2.50',
        'tags': <String>[],
      };
      expect(
        metadataPatch('books', original, values, {
          'title',
          'titleLock',
          'numberSort',
          'tags',
        }),
        {'title': 'New', 'titleLock': true, 'numberSort': 2.5, 'tags': []},
      );
      expect(
        metadataPatch('books', {'summary': 'old'}, {'summary': ' '}, {
          'summary',
        }),
        {'summary': null},
      );
      expect(metadataPatch('series', {}, {'ageRating': '0'}, {'ageRating'}), {
        'ageRating': 0,
      });
      expect(
        () => metadataPatch('series', {}, {'ageRating': '-1'}, {'ageRating'}),
        throwsFormatException,
      );
      expect(
        () => metadataPatch(
          'books',
          {},
          {'releaseDate': '2024-13-01'},
          {'releaseDate'},
        ),
        throwsFormatException,
      );
      expect(
        () => metadataPatch(
          'books',
          {},
          {
            'links': [
              {'label': 'bad', 'url': 'javascript:alert(1)'},
            ],
          },
          {'links'},
        ),
        throwsFormatException,
      );
    },
  );

  test('batch metadata clearing stays explicit', () {
    expect(
      metadataPatch(
        'books',
        {},
        {'summary': '', 'tags': []},
        {'summary', 'tags'},
        forceExplicit: true,
      ),
      {'summary': null, 'tags': []},
    );
  });
  late Directory directory;
  late LocalStore store;
  late Repository repository;
  final requests = <http.Request>[];
  Json remote = {
    'id': 'list',
    'name': 'Original',
    'ordered': true,
    'summary': '',
    'bookIds': ['a', 'b'],
  };
  setUp(() {
    directory = Directory.systemTemp.createTempSync('catalog-tools-');
    store = LocalStore(sqlite3.openInMemory());
    requests.clear();
    remote = {
      'id': 'list',
      'name': 'Original',
      'ordered': true,
      'summary': '',
      'bookIds': ['a', 'b'],
    };
    repository = Repository(
      profile: const ServerProfile(
        id: 's',
        name: 'Test',
        url: 'https://example.invalid',
        email: 'test@example.invalid',
        authentication: Authentication.apiKey,
        admin: true,
      ),
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.apiKey,
        credential: 'synthetic',
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'PATCH' || request.method == 'DELETE') {
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/books')) {
            return http.Response(
              jsonEncode({'content': [], 'last': true, 'totalElements': 0}),
              200,
            );
          }
          return http.Response(jsonEncode(remote), 200);
        }),
      ),
    );
  });
  tearDown(() {
    repository.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });
  test(
    'saved filters and pins are scoped to the account, persist all query state',
    () {
      final tools = CatalogTools(repository);
      final preset = FilterPreset.create(
        'Mine',
        'books',
        CatalogFilter(
          entries: [
            {'field': 'tag', 'operator': 'is', 'value': 'tag'},
          ],
        ),
        search: 'word',
        sort: 'createdDate,desc',
        smart: true,
      );
      tools.savePreset(preset);
      tools.pin('presets', preset.id);
      expect(tools.presets.single.toJson(), preset.toJson());
      expect(tools.pinned('presets'), [preset.id]);
      expect(store.setting<List<dynamic>>('filters:another'), isNull);
      tools.deletePreset(preset.id);
      expect(tools.presets, isEmpty);
      expect(requests, isEmpty);
    },
  );
  test(
    'list update refuses concurrent membership edits and empty membership',
    () async {
      final tools = CatalogTools(repository);
      final original = {...remote};
      remote = {
        ...remote,
        'bookIds': ['a', 'c'],
      };
      await expectLater(
        tools.updateList('readlists', 'list', original, {
          'bookIds': ['b', 'a'],
        }),
        throwsA(isA<ApiFailure>()),
      );
      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
      await expectLater(
        tools.updateList('readlists', 'list', remote, {'bookIds': []}),
        throwsFormatException,
      );
      await tools.updateList('readlists', 'list', remote, {'name': 'Renamed'});
      expect(jsonDecode(requests.last.body), {'name': 'Renamed'});
      expect(object(store.cached('s', 'detail:readlists:list'))['bookIds'], [
        'a',
        'c',
      ]);
      store.setSetting('pinned:readlists:s', ['list']);
      await tools.deleteList('readlists', 'list');
      expect(tools.pinned('readlists'), isEmpty);
      expect(store.cached('s', 'detail:readlists:list'), isNull);
    },
  );
  test('read list read status is sent as a GET query parameter', () async {
    await repository.catalog(
      'books',
      path: '/api/v1/readlists/list/books',
      condition: {
        'allOf': [
          {
            'readStatus': {'operator': 'is', 'value': 'READ'},
          },
        ],
      },
    );
    expect(requests.single.url.queryParameters['read_status'], 'READ');
    expect(requests.single.body, isEmpty);
    expect(requests.single.url.queryParameters.containsKey('sort'), isFalse);
  });
  test('bulk completion of unknown-length ebooks is durable and omits invalid page zero', () async {
    repository.setOffline(true);
    final book = Book({
      'id': 'epub',
      'media': {'pagesCount': 0, 'mediaType': 'application/epub+zip'},
    });
    await CatalogTools(repository).batchProgress([
      CatalogItem('books', book.json),
      CatalogItem('books', book.json),
    ], true);
    expect(repository.pendingCount, 1);
    expect(repository.overlay(book).completed, isTrue);
    expect(repository.overlay(book).fraction, 1);
    repository.offline = false;
    await repository.sync();
    expect(jsonDecode(requests.last.body), {'completed': true});
    expect(repository.pendingCount, 0);
  });
}
