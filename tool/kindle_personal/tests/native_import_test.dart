import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/local_library.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_document.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'prepared Kindle prototype outputs import and reopen in KMReader offline',
    () async {
      final fixtures = Platform.environment['KMREADER_KINDLE_FIXTURES'];
      expect(
        fixtures,
        isNotNull,
        reason: 'Run prototype self-test --fixtures first.',
      );
      final directory = Directory.systemTemp.createTempSync(
        'kindle-native-import-',
      );
      final store = LocalStore(
        sqlite3.open('${directory.path}/library.sqlite'),
      );
      var library = LocalLibrary(store: store, directory: directory);
      try {
        final epub = File('$fixtures/synthetic-EBOK.epub');
        final pdf = File('$fixtures/synthetic-PDOC.pdf');
        final ebook = await library.importFile(XFile(epub.path));
        final document = await library.importFile(XFile(pdf.path));
        final converted = await library.importFile(
          XFile('$fixtures/synthetic-KFX.epub'),
        );
        expect(ebook.format, 'epub');
        expect(document.format, 'pdf');
        expect(ebook.pages, 1);
        final parsed = EpubDocument.open(library.bookFile(ebook).path);
        try {
          expect(parsed.title, 'KMReader synthetic Kindle test');
          expect(
            parsed.chapter(0),
            contains('Questo testo non proviene da Amazon.'),
          );
        } finally {
          parsed.close();
        }
        final kfx = EpubDocument.open(library.bookFile(converted).path);
        try {
          expect(kfx.chapter(0), contains('Questo documento sintetico'));
        } finally {
          kfx.close();
        }
        library.setProgress(ebook, 1);
        library.dispose();
        library = LocalLibrary(store: store, directory: directory);
        expect(library.offline, isTrue);
        expect(library.books, hasLength(3));
        expect(
          library.bookFile(await library.book(ebook.id)).existsSync(),
          isTrue,
        );
        expect(
          library
              .bookFile(await library.book(document.id))
              .readAsBytesSync()
              .take(5),
          '%PDF-'.codeUnits,
        );
        expect(store.pendingCount(LocalLibrary.scope), 0);
      } finally {
        library.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
