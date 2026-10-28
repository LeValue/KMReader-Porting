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
