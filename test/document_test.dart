import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/epub_document.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  test('EPUB reads spine order and chapter resources without filesystem extraction', () {
    final document = EpubDocument.open('test/fixtures/sample.epub');
    try {
      expect(document.title, 'Synthetic EPUB');
      expect(document.chapters.length, 2);
      expect(document.chapters.first.title, 'First Chapter');
      expect(document.chapter(1), contains('Second Chapter'));
      expect(
        EpubDocument.resolve('OPS/one.xhtml', 'two.xhtml#heading'),
        'OPS/two.xhtml',
      );
      expect(
        () => EpubDocument.resolve('OPS/one.xhtml', '../../etc/passwd'),
        throwsFormatException,
      );
      expect(
        () => document.resource('OPS/missing.xhtml'),
        throwsFormatException,
      );
    } finally {
      document.close();
    }
  });
  test('native PDF engine opens and extracts searchable text', () async {
    final cache = Directory.systemTemp.createTempSync('kmreader-pdf-');
    Pdfrx.cacheDirectoryPath = cache.path;
    final suffix = Platform.isWindows
        ? 'win-x64/pdfium.dll'
        : 'linux-x64/libpdfium.so';
    final module = Directory('.dart_tool/hooks_runner/shared/pdfium_dart/build')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) => file.path.replaceAll('\\', '/').endsWith(suffix));
    Pdfrx.pdfiumModulePath = module.absolute.path;
    await pdfrxInitialize();
    final document = await PdfDocument.openFile('test/fixtures/sample.pdf');
    try {
      expect(document.pages.length, 1);
      final text = await document.pages.first.loadText();
      expect(text, isNotNull);
      expect(text!.fullText, contains('Hello KMReader'));
    } finally {
      await document.dispose();
      cache.deleteSync(recursive: true);
    }
  });
}
