import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

File fixture(
  Directory directory, {
  Map<String, List<int>> resources = const {},
  int paragraphCount = 120,
  String readingDirection = 'ltr',
}) {
  final paragraphs = List.generate(
    paragraphCount,
    (i) =>
        '<p>Paragraph $i contains enough text to span multiple browser pages and test retained positions after layout changes.</p>',
  ).join();
  final files = {
    'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>',
    'OPS/package.opf':
        '<package unique-identifier="uid"><metadata><identifier id="uid">urn:uuid:550e8400-e29b-41d4-a716-446655440000</identifier><language>en</language><title>Browser fixture</title></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/></manifest><spine page-progression-direction="$readingDirection"><itemref idref="one"/><itemref idref="two"/><itemref idref="notes" linear="no"/></spine></package>',
    'OPS/one.xhtml':
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter one</title></head><body><h1>Chapter one</h1><a href="notes.xhtml#note">Footnote</a>$paragraphs</body></html>',
    'OPS/two.xhtml':
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter two</title></head><body><h1>Chapter two</h1>$paragraphs</body></html>',
    'OPS/notes.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="note">Supplementary note</h1><a href="one.xhtml">Back</a></body></html>',
  };
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  for (final entry in resources.entries) {
    archive.removeFile(
      archive.findFile(entry.key) ?? ArchiveFile.bytes('missing', []),
    );
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return File('${directory.path}/browser.epub')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
}

File verticalEpubFixture(Directory directory) => fixture(
  directory,
  resources: {
    'OPS/package.opf': utf8.encode(
      '''<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">vertical-test</dc:identifier><dc:title>縦書き</dc:title><dc:language>ja</dc:language></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/></manifest><spine page-progression-direction="rtl"><itemref idref="one"/></spine></package>''',
    ),
    'OPS/one.xhtml': utf8.encode(
      '''<html xmlns="http://www.w3.org/1999/xhtml" lang="ja"><head><title>縦書き</title><style>body{writing-mode:vertical-rl;text-orientation:mixed}p{margin:0 1em}</style></head><body>${List.generate(120, (i) => '<p id="p$i">縦書き段落$i。日本語の文章でページ送りと文字サイズを変更した場合の読書位置を確認します。</p>').join()}</body></html>''',
    ),
  },
);

File fixedLayoutFixture(Directory directory) => fixture(
  directory,
  resources: {
    'OPS/package.opf': utf8.encode(
      '''<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">fixed-layout-test</dc:identifier><dc:title>Fixed pages</dc:title><dc:language>en</dc:language><meta property="rendition:layout">pre-paginated</meta><meta property="rendition:spread">none</meta></metadata>
<manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>''',
    ),
    for (final (name, size) in [('one', (600, 800)), ('two', (800, 600))])
      'OPS/$name.xhtml': utf8.encode(
        '''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$name</title><meta name="viewport" content="width=${size.$1},height=${size.$2}"/><style>html,body{margin:0;padding:0;width:${size.$1}px;height:${size.$2}px;background:#ffeedd;color:#112233}body{font-size:18px;line-height:1.2}.label{position:absolute;left:120px;top:200px;margin:0;font-size:inherit}</style></head><body><p class="label" id="label">Authored $name page</p></body></html>''',
      ),
  },
);
