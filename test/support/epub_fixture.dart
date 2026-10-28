import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

File fixture(
  Directory directory, {
  Map<String, List<int>> resources = const {},
}) {
  final paragraphs = List.generate(
    120,
    (i) =>
        '<p>Paragraph $i contains enough text to span multiple browser pages and test retained positions after layout changes.</p>',
  ).join();
  final files = {
    'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>',
    'OPS/package.opf': '<package unique-identifier="uid"><metadata><identifier id="uid">urn:uuid:550e8400-e29b-41d4-a716-446655440000</identifier><language>en</language><title>Browser fixture</title></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/><itemref idref="notes" linear="no"/></spine></package>',
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
