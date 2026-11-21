import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

Json book(
  String id,
  String title, {
  String library = 'a',
  String author = 'Ursula',
  num number = 1,
  bool read = false,
}) => {
  'id': id,
  'name': title,
  'seriesId': 'series',
  'libraryId': library,
  'metadata': {
    'title': title,
    'numberSort': number,
    'authors': [
      {'name': author, 'role': 'writer'},
    ],
    'tags': ['space'],
    'releaseDate': '2026-10-01',
  },
  'media': {'pagesCount': 100, 'mediaProfile': 'EPUB'},
  'readProgress': {'completed': read, 'page': read ? 100 : 0},
};
void main() {
  late LocalStore store;
  setUp(() => store = LocalStore(sqlite3.openInMemory()));
  tearDown(() => store.close());
  void seed() {
    store.cacheBooks('a', [
      CatalogItem('books', book('one', 'Café Space', number: 2)),
      CatalogItem(
        'books',
        book('two', 'Space Two', library: 'b', number: 10, read: true),
      ),
      CatalogItem('books', book('three', '夜空の星')),
    ]);
    store.cacheBooks('b', [
      CatalogItem('books', book('secret', 'Space Secret')),
    ]);
  }

  test('dashboard date sort aliases use the stored catalog dates', () {
    store.cacheBooks('a', [
      CatalogItem('books', {
        ...book('old', 'Old'),
        'created': '2020-01-01',
        'lastModified': '2024-01-01',
      }),
      CatalogItem('books', {
        ...book('new', 'New'),
        'created': '2026-01-01',
        'lastModified': '2025-01-01',
      }),
    ]);
    expect(
      store.offlineCatalog
          .query('a', 'books', sort: 'createdDate,desc')
          .items
          .first
          .id,
      'new',
    );
    expect(
      store.offlineCatalog
          .query('a', 'books', sort: 'lastModifiedDate,asc')
          .items
          .first
          .id,
      'old',
    );
  });

  test(
    'On Deck selects the next unread volume per idle series before pagination',
    () {
      CatalogItem volume(
        String id,
        String series,
        int number, {
        String library = 'a',
        Json? progress,
      }) => CatalogItem('books', {
        ...book(id, id, number: number, library: library),
        'seriesId': series,
        'readProgress': progress,
      });
      Json completed(String date) => {
        'page': 100,
        'completed': true,
        'readDate': date,
        'lastModified': date,
      };
      store.cacheBooks('a', [
        volume('alpha-read', 'alpha', 1, progress: completed('2026-11-01')),
        volume('alpha-next', 'alpha', 2),
        volume('alpha-later', 'alpha', 3),
        volume('beta-read', 'beta', 1),
        volume('beta-next', 'beta', 2),
        volume('busy-read', 'busy', 1, progress: completed('2026-11-02')),
        volume('busy-started', 'busy', 2),
        volume('busy-next', 'busy', 3),
        volume(
          'other-read',
          'other',
          1,
          library: 'b',
          progress: completed('2026-11-10'),
        ),
        volume('other-next', 'other', 2, library: 'b'),
        volume('reset-read', 'reset', 1, progress: completed('2026-11-10')),
        volume('reset-next', 'reset', 2),
        volume('secret-next', 'secret', 2),
      ]);
      store.cacheBooks('b', [
        volume('secret-read', 'secret', 1, progress: completed('2026-11-11')),
      ]);
      store.recordProgress('a', 'beta-read', {
        'kind': 'epub',
        'lastModified': '2026-11-08',
        'progression': {
          'locator': {
            'locations': {'totalProgression': 1},
          },
        },
      });
      store.recordProgress('a', 'alpha-read', {
        'reset': true,
        'lastModified': '2026-10-31',
      }, pending: false);
      store.recordProgress('a', 'busy-started', {'page': 7});
      store.recordProgress('a', 'reset-read', {'reset': true}, pending: true);
      CatalogPage deck(int page, {String? library}) =>
          store.offlineCatalog.query(
            'a',
            'books',
            path: '/api/v1/books/ondeck',
            page: page,
            size: 1,
            libraryId: library,
          );
      expect(deck(0).total, 3);
      expect(
        [for (var page = 0; page < 3; page++) deck(page).items.single.id],
        ['other-next', 'beta-next', 'alpha-next'],
      );
      expect(deck(0, library: 'a').total, 2);
      expect(deck(1, library: 'a').items.single.id, 'alpha-next');
      expect(deck(1, library: 'a').last, isTrue);
    },
  );

  test('offline full-text search, Unicode, filters, sort, pagination and account isolation', () {
    seed();
    final index = store.offlineCatalog;
    expect(
      index.query('a', 'books', search: 'cafe spa').items.single.id,
      'one',
    );
    expect(index.query('a', 'books', search: '空の').items.single.id, 'three');
    expect(index.query('a', 'books', search: 'secret').items, isEmpty);
    final filter = {
      'allOf': [
        {
          'author': {
            'operator': 'is',
            'value': {'name': 'Ursula'},
          },
        },
        {
          'anyOf': [
            {
              'title': {'operator': 'beginsWith', 'value': 'Café'},
            },
            {
              'title': {'operator': 'endsWith', 'value': 'Two'},
            },
          ],
        },
      ],
    };
    final result = index.query(
      'a',
      'books',
      condition: filter,
      sort: 'metadata.numberSort,desc',
      size: 1,
    );
    expect(result.total, 2);
    expect(result.last, false);
    expect(result.items.single.id, 'two');
    expect(
      index
          .query(
            'a',
            'books',
            condition: filter,
            sort: 'metadata.numberSort,desc',
            size: 1,
            page: 1,
          )
          .items
          .single
          .id,
      'one',
    );
    expect(index.query('a', 'books', libraryId: 'b').items.single.id, 'two');
    expect(
      index
          .query(
            'a',
            'books',
            condition: {
              'tag': {'operator': 'isNot', 'value': 'space'},
            },
          )
          .items,
      isEmpty,
    );
    // Quoted FTS operators and SQL syntax remain ordinary user input.
    expect(index.query('a', 'books', search: '" OR 1=1 --').items, isEmpty);
  });
  test('metadata refresh and deletion update FTS, read filters use durable local progress', () {
    seed();
    store.cacheBooks('a', [CatalogItem('books', book('one', 'Changed'))]);
    expect(
      store.offlineCatalog.query('a', 'books', search: 'cafe').items,
      isEmpty,
    );
    expect(
      store.offlineCatalog
          .query('a', 'books', search: 'changed')
          .items
          .single
          .id,
      'one',
    );
    store.recordProgress('a', 'one', {'page': 3, 'completed': false});
    expect(
      store.offlineCatalog
          .query(
            'a',
            'books',
            condition: {
              'readStatus': {'operator': 'is', 'value': 'IN_PROGRESS'},
            },
          )
          .items
          .single
          .id,
      'one',
    );
    store.offlineCatalog.remove('a', 'books', 'one');
    expect(
      store.offlineCatalog.query('a', 'books', search: 'changed').items,
      isEmpty,
    );
    store.removeServer('a');
    expect(store.offlineCatalog.count('a', 'books'), 0);
    expect(store.offlineCatalog.count('b', 'books'), 1);
  });
  test('list order sources and pre-index cache migration remain usable', () {
    seed();
    store.cache('a', 'detail:readlists:list', {
      'id': 'list',
      'name': 'List',
      'ordered': true,
      'bookIds': ['three', 'one'],
    });
    expect(
      store.offlineCatalog
          .query('a', 'books', path: '/api/v1/readlists/list/books')
          .items
          .map((v) => v.id),
      ['three', 'one'],
    );
    final db = sqlite3.openInMemory();
    db.execute(
      'CREATE TABLE cache(server TEXT,key TEXT,value TEXT,updated INTEGER DEFAULT 0,PRIMARY KEY(server,key))',
    );
    db.execute('INSERT INTO cache(server,key,value) VALUES(?,?,?)', [
      'legacy',
      'book:old',
      jsonEncode(book('old', 'Legacy')),
    ]);
    final migrated = LocalStore(db);
    addTearDown(migrated.close);
    expect(
      migrated.offlineCatalog
          .query('legacy', 'books', search: 'legacy')
          .items
          .single
          .id,
      'old',
    );
  });
}
