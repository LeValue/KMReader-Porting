import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/local_library.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/epub_fixture.dart';
import 'support/pdf_fixture.dart';

void main() {
  late Directory directory;
  late LocalStore store;
  late LocalLibrary library;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('local-books-');
    store = LocalStore(sqlite3.open('${directory.path}/library.sqlite'));
    library = LocalLibrary(store: store, directory: directory);
  });
  tearDown(() {
    library.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });
  File comic() {
    final archive = Archive();
    for (final (name, content) in [
      ('10.png', [10]),
      ('2.png', [2]),
      ('1.png', [1]),
      ('__MACOSX/._1.png', [99]),
      ('notes.txt', [99]),
    ]) {
      archive.addFile(ArchiveFile.bytes(name, content));
    }
    return File('${directory.path}/source.cbz')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test(
    'local comics import once, survive reopening and sort pages naturally',
    () async {
      final original = comic();
      final imports = await Future.wait([
        library.importFile(XFile(original.path)),
        library.importFile(XFile(original.path)),
      ]);
      final book = imports.first;
      expect(imports.last.id, book.id);
      expect(book.pages, 3);
      expect(book.format, 'comic');
      expect((await library.importFile(XFile(original.path))).id, book.id);
      expect(library.books, hasLength(1));
      final pages = LocalComicPages(library.bookFile(book));
      expect(await pages.page(1), [1]);
      expect(await pages.page(2), [2]);
      expect(await pages.page(3), [10]);
      await expectLater(pages.page(4), throwsRangeError);
      library.setProgress(book, 2);
      expect(store.pendingCount(LocalLibrary.scope), 0);
      expect(store.servers, isEmpty);
      library.dispose();
      library = LocalLibrary(store: store, directory: directory);
      expect(library.books.single.page, 2);
      await library.remove(library.books.single);
      expect(library.books, isEmpty);
      expect(original.existsSync(), isTrue);
      expect(library.bookFile(book).existsSync(), isFalse);
    },
  );
  test(
    'EPUB and PDF copies remain readable after original files are removed',
    () async {
      final epub = fixture(directory);
      final pdf = File('${directory.path}/book.pdf')
        ..writeAsBytesSync(rasterPdfFixture());
      final ebook = await library.importFile(XFile(epub.path));
      final document = await library.importFile(XFile(pdf.path));
      expect(ebook.format, 'epub');
      expect(document.format, 'pdf');
      epub.deleteSync();
      pdf.deleteSync();
      expect(library.bookFile(ebook).existsSync(), isTrue);
      expect(library.bookFile(document).readAsBytesSync(), rasterPdfFixture());
      library.setEpubProgress(
        ebook,
        'OPS/two.xhtml',
        .4,
        .7,
        cfi: 'epubcfi(/6/4!/4/2:1)',
      );
      expect(store.pendingCount(LocalLibrary.scope), 0);
      expect(store.progress(LocalLibrary.scope, ebook.id)!['kind'], 'epub');
    },
  );
  test(
    'invalid files leave neither a library entry nor partial copies',
    () async {
      final file = File('${directory.path}/bad.epub')
        ..writeAsStringSync('invalid');
      await expectLater(
        library.importFile(XFile(file.path)),
        throwsA(anything),
      );
      expect(library.books, isEmpty);
      expect(library.root.listSync(), isEmpty);
      final rar = File('${directory.path}/unsupported.cbr')
        ..writeAsStringSync('Rar!');
      await expectLater(
        library.importFile(XFile(rar.path)),
        throwsFormatException,
      );
      expect(rar.existsSync(), isTrue);
    },
  );
}
