import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_session.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/features/reader/epub_page_index.dart';

import 'support/epub_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'closing waits for background archive indexing before deleting the EPUB',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'epub-close-index-',
      );
      final store = LocalStore(sqlite3.openInMemory());
      final repository = Repository(
        profile: const ServerProfile(
          id: 'test',
          name: 'Test',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        ),
        api: KomgaApi(
          Uri.parse('https://example.invalid'),
          authentication: Authentication.apiKey,
          credential: '',
        ),
        store: store,
        directory: directory,
      )..offline = true;
      try {
        final file = fixture(directory, paragraphCount: 5000);
        final session = await EpubSession.open(
          repository,
          Book({'id': 'volume', 'name': 'volume.epub'}),
          file,
        );
        await session.close();
        await file.delete();
        expect(await file.exists(), false);
      } finally {
        repository.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
  for (final publisher in [false, true]) {
    test(
      'volume counter trusts publisher pagination only: $publisher',
      () async {
        final directory = Directory.systemTemp.createTempSync('epub-volume-');
        final store = LocalStore(sqlite3.openInMemory());
        final repository = Repository(
          profile: const ServerProfile(
            id: 'test',
            name: 'Test',
            url: 'https://example.invalid',
            email: '',
            authentication: Authentication.apiKey,
          ),
          api: KomgaApi(
            Uri.parse('https://example.invalid'),
            authentication: Authentication.apiKey,
            credential: '',
          ),
          store: store,
          directory: directory,
        )..offline = true;
        EpubSession? session;
        try {
          final book = Book({
            'id': 'volume',
            'media': {
              'mediaProfile': 'EPUB',
              'pagesCount': 79,
              if (publisher) 'pagesCountSource': 'publisher',
            },
          });
          session = await EpubSession.open(
            repository,
            book,
            fixture(directory),
          );
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (session.pageIndex == null &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(session.pageIndex, isNotNull);
          expect(
            session.totalBookPages,
            publisher ? 79 : session.pageIndex!.pages,
          );
          if (!publisher) expect(session.totalBookPages, isNot(79));
        } finally {
          await session?.close();
          repository.dispose();
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
  test('volume pages are weighted by chapter content and navigate across chapter boundaries', () {
    final index = EpubPageIndex([1024, 9216]);
    expect(index.pages, 10);
    expect(index.page(1, 0), 2);
    expect(index.page(1, 1), 10);
    expect(index.fraction(1, .5), .55);
    expect(index.target(.55).$1, 1);
    expect(index.target(.55).$2, closeTo(.5, .000001));
    expect(index.target(1).$1, 1);
  });
  test('background text index counts Unicode scalars and excludes styles and scripts', () {
    final directory = Directory.systemTemp.createTempSync('epub-count-');
    try {
      final file = fixture(
        directory,
        resources: {
          'OPS/one.xhtml': utf8.encode(
            '<html><head><title>Ignored</title><style>long style</style></head><body>😀 città<script>ignored script</script><style>ignored</style></body></html>',
          ),
          'OPS/two.xhtml': utf8.encode(
            '<html><body>${'x' * 1024}</body></html>',
          ),
        },
      );
      expect(indexEpubFile(file.path), [7, 1024]);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
