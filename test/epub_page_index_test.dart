import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/epub_page_index.dart';

import 'support/epub_fixture.dart';

void main() {
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
