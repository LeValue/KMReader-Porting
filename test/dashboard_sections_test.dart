import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/dashboard.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('recent books and comics filter before pagination and ignore publication age', () async {
    final directory = Directory.systemTemp.createTempSync('dashboard-types-');
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'komga',
      name: 'Test',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    final repo = Repository(
      profile: profile,
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: '',
      ),
    )..setOffline(true);
    addTearDown(() async {
      await repo.stopDownloadWork();
      store.close();
      directory.deleteSync(recursive: true);
    });
    store.cacheBooks(profile.id, [
      for (var i = 0; i < 30; i++)
        CatalogItem('books', {
          'id': 'comic-$i',
          'libraryId': 'library',
          'created': '2026-11-07T00:00:00Z',
          'media': {'mediaProfile': 'DIVINA'},
          'metadata': {'title': 'Comic $i'},
        }),
      CatalogItem('books', {
        'id': 'epub',
        'libraryId': 'library',
        'created': '2026-10-01T00:00:00Z',
        'media': {'mediaProfile': 'EPUB'},
        'metadata': {
          'title': 'Old novel, newly added',
          'releaseDate': '1900-01-01',
        },
      }),
      CatalogItem('books', {
        'id': 'pdf',
        'libraryId': 'library',
        'created': '2026-10-02T00:00:00Z',
        'media': {'mediaProfile': 'PDF'},
        'metadata': {'title': 'Document without release date'},
      }),
      CatalogItem('books', {
        'id': 'other',
        'libraryId': 'other',
        'created': '2026-12-01T00:00:00Z',
        'media': {'mediaProfile': 'EPUB'},
        'metadata': {'title': 'Other library'},
      }),
    ]);
    final books = DashboardQuery(
      'dashboard.recentlyReleasedBooks',
      libraryId: 'library',
    );
    final comics = DashboardQuery(
      'dashboard.recentlyAddedBooks',
      libraryId: 'library',
    );
    expect(books.sort, 'created,desc');
    final first = await repo.catalog(
      books.kind,
      condition: books.condition,
      sort: books.sort,
      size: 1,
    );
    expect(first.total, 2);
    expect(first.items.single.id, 'pdf');
    final second = await repo.catalog(
      books.kind,
      condition: books.condition,
      sort: books.sort,
      size: 1,
      page: 1,
    );
    expect(second.items.single.id, 'epub');
    final recentComics = await repo.catalog(
      comics.kind,
      condition: comics.condition,
      sort: comics.sort,
      size: 12,
    );
    expect(recentComics.total, 30);
    expect(
      recentComics.items.every((item) => item.book.format == 'comic'),
      true,
    );
  });
  test('recently read preserves read status and library scope', () {
    final read = DashboardQuery(
      'dashboard.recentlyReadBooks',
      libraryId: 'library',
    );
    expect(read.kind, 'books');
    expect(read.path, isNull);
    expect(read.sort, 'readProgress.readDate,desc');
    final conditions = read.condition!['allOf'] as List;
    expect(conditions, [
      {
        'readStatus': {'operator': 'is', 'value': 'READ'},
      },
      {
        'libraryId': {'operator': 'is', 'value': 'library'},
      },
    ]);
    expect(
      dashboardSections,
      containsAll([
        'dashboard.recentlyReadBooks',
        'dashboard.recentlyReleasedBooks',
      ]),
    );
    expect(
      dashboardCardKinds.keys,
      containsAll(['large', 'medium', 'small', 'horizontal']),
    );
  });
}
