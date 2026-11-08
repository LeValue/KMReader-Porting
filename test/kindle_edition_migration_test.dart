import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/edition_migration.dart';

import 'support/epub_fixture.dart';

void main() {
  test('edition remapping preserves exact Unicode text position across IDs and paths', () async {
    final root = Directory.systemTemp.createTempSync('kindle-editions-');
    addTearDown(() => root.deleteSync(recursive: true));
    File book(
      String name,
      int position,
      String id, {
      String text = 'A🦆bc',
      bool duplicate = false,
    }) {
      final dir = Directory('${root.path}/$name')..createSync();
      return fixture(
        dir,
        resources: {
          'OPS/package.opf': utf8.encode(
            '<package><metadata><title>$name</title></metadata><manifest><item id="one" href="$name.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>',
          ),
          'OPS/$name.xhtml': utf8.encode(
            '<html><head><title>$name</title></head><body><p id="$id">$text</p>${duplicate ? '<p id="duplicate">$text</p>' : ''}</body></html>',
          ),
          'META-INF/kmreader-kindle.json': utf8.encode(
            jsonEncode({
              'schema': 1,
              'position_units': 'unicode_scalars',
              'container_acrs': [name],
              'primary_acr': name,
              'entries': [
                {
                  'path': 'OPS/$name.xhtml',
                  'id': id,
                  'position': position,
                  'length': text.runes.length,
                },
                if (duplicate)
                  {
                    'path': 'OPS/$name.xhtml',
                    'id': 'duplicate',
                    'position': position + 20,
                    'length': text.runes.length,
                  },
              ],
            }),
          ),
        },
      );
    }

    final old = book('before', 10, 'old'), updated = book('after', 100, 'new');
    final migration = await KindleEditionMigration.open(old.path, updated.path);
    expect(migration.position(12), 102);
    expect(migration.locator(12), containsPair('id', 'new'));
    expect(migration.locator(12), containsPair('offset', 2));
    expect(migration.cfiPosition('epubcfi(/6/2!/4/2[old]/1:3)'), 12);
    expect(
      () => migration.cfiPosition('epubcfi(/6/2!/4/2[wrong]/1:3)'),
      throwsA(isA<KindleFailure>()),
    );
    // A UTF-16 offset inside a surrogate pair is not a text boundary.
    expect(
      () => migration.cfiPosition('epubcfi(/6/2!/4/2/1:2)'),
      throwsA(isA<KindleFailure>()),
    );
    final marks = migration.bookmarks([
      {'cfi': 'epubcfi(/6/2!/4/2[old]/1:3)', 'label': 'Saved'},
    ]);
    expect(marks.single['kindlePosition'], 102);
    expect(marks.single['href'], 'after.xhtml');
    expect(marks.single['label'], 'Saved');
    expect(marks.single['cfi'], isEmpty);
    final ambiguous = await KindleEditionMigration.open(
      old.path,
      book('duplicate', 200, 'new', duplicate: true).path,
    );
    expect(() => ambiguous.position(12), throwsA(isA<KindleFailure>()));
    final changed = await KindleEditionMigration.open(
      old.path,
      book('changed', 300, 'new', text: 'Changed').path,
    );
    expect(() => changed.position(12), throwsA(isA<KindleFailure>()));
    expect(() => migration.position(999), throwsA(isA<KindleFailure>()));
  });
}
