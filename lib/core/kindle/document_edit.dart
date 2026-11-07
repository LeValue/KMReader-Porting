import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../features/reader/epub_document.dart';
import 'client.dart';

/// Produces a new EPUB; the source and every reading-content resource stay
/// untouched. ZIP/image work runs off the Flutter UI isolate.
Future<void> editKindleEpub({
  required String source,
  required String target,
  required String title,
  required String author,
  String? cover,
  String? summary,
  String? language,
}) => Isolate.run(
  () => _edit(source, target, title, author, cover, summary, language),
);

void _edit(
  String source,
  String target,
  String title,
  String author,
  String? cover,
  String? summary,
  String? language,
) {
  if (title.trim().isEmpty || title.length > 250 || author.length > 250) {
    throw const KindleFailure('import_metadata');
  }
  if (summary != null && summary.length > 4000 ||
      language != null &&
          language.isNotEmpty &&
          !RegExp(r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$')
              .hasMatch(language)) {
    throw const KindleFailure('import_metadata');
  }
  final destination = File(target), original = File(source);
  if (!original.existsSync() ||
      original.lengthSync() > 200 * 1024 * 1024 ||
      destination.existsSync() ||
      p.equals(p.absolute(source), p.absolute(target))) {
    throw const KindleFailure('management_source');
  }
  final input = InputFileStream(source);
  final partial = File('$target.part');
  OutputFileStream? output;
  try {
    final archive = ZipDecoder().decodeStream(input, verify: true);
    final names = <String>{};
    var expanded = 0;
    for (final file in archive) {
      if (!names.add(file.name) ||
          file.name.startsWith('/') ||
          file.name.contains('\\') ||
          file.name.split('/').contains('..') ||
          file.isSymbolicLink) {
        throw const KindleFailure('management_source');
      }
      expanded += file.size;
      if (file.size > 32 * 1024 * 1024 || expanded > 512 * 1024 * 1024) {
        throw const KindleFailure('management_source');
      }
    }
    String read(String name) {
      final entry = archive.findFile(name);
      if (entry == null || entry.size > 4 * 1024 * 1024) {
        throw const KindleFailure('management_source');
      }
      return EpubDocument.decodeText(entry.content);
    }

    final container = XmlDocument.parse(read('META-INF/container.xml'));
    final packagePath =
        container
            .findAllElements('rootfile')
            .firstOrNull
            ?.getAttribute('full-path') ??
        container.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'rootfile')
            .firstOrNull
            ?.getAttribute('full-path');
    if (packagePath == null) throw const KindleFailure('management_source');
    final safePackage = EpubDocument.resolve('container.xml', packagePath);
    final package = XmlDocument.parse(read(safePackage));
    final metadata = package.descendants.whereType<XmlElement>().firstWhere(
      (e) => e.name.local == 'metadata',
    );
    const dc = 'http://purl.org/dc/elements/1.1/';
    metadata.setAttribute('xmlns:dc', dc);
    for (final (name, value) in [
      ('title', title.trim()),
      ('creator', author.trim()),
      if (summary != null) ('description', summary),
      if (language != null && language.isNotEmpty) ('language', language),
    ]) {
      final existing = metadata.childElements
          .where((e) => e.name.local == name)
          .firstOrNull;
      if (existing != null) {
        existing.children
          ..clear()
          ..add(XmlText(value));
        if (name == 'creator') {
          existing.removeAttribute(
            'file-as',
            namespaceUri: 'http://www.idpf.org/2007/opf',
          );
        }
      } else if (value.isNotEmpty) {
        metadata.children.add(
          XmlElement(XmlName.parts(name, prefix: 'dc'), [], [XmlText(value)]),
        );
      }
    }
    final replacements = <String, List<int>>{};
    if (cover != null) {
      final imageFile = File(cover);
      if (imageFile.lengthSync() > 20 * 1024 * 1024) {
        throw const KindleFailure('management_cover');
      }
      final decoder = img.findDecoderForData(imageFile.readAsBytesSync());
      final info = decoder?.startDecode(imageFile.readAsBytesSync());
      if (info == null ||
          info.width <= 0 ||
          info.height <= 0 ||
          info.width * info.height > 24000000) {
        throw const KindleFailure('management_cover');
      }
      var image = decoder!.decodeFrame(0);
      if (image == null) throw const KindleFailure('management_cover');
      if (image.width > 2048 || image.height > 2048) {
        image = img.copyResize(
          image,
          width: image.width >= image.height ? 2048 : null,
          height: image.height > image.width ? 2048 : null,
        );
      }
      final manifest = package.descendants.whereType<XmlElement>().firstWhere(
        (e) => e.name.local == 'manifest',
      );
      final entries = manifest.childElements.where(
        (e) => e.name.local == 'item',
      );
      final oldMeta = metadata.childElements
          .where(
            (e) => e.name.local == 'meta' && e.getAttribute('name') == 'cover',
          )
          .firstOrNull;
      var entry =
          entries
              .where(
                (e) => (e.getAttribute('properties') ?? '')
                    .split(' ')
                    .contains('cover-image'),
              )
              .firstOrNull ??
          entries
              .where(
                (e) =>
                    oldMeta != null &&
                    e.getAttribute('id') == oldMeta.getAttribute('content'),
              )
              .firstOrNull;
      if (entry != null &&
          !const {
            'image/jpeg',
            'image/png',
          }.contains(entry.getAttribute('media-type'))) {
        throw const KindleFailure('management_cover_layout');
      }
      String path;
      if (entry != null &&
          const {
            'image/jpeg',
            'image/png',
          }.contains(entry.getAttribute('media-type'))) {
        path = EpubDocument.resolve(safePackage, entry.getAttribute('href')!);
      } else {
        var id = 'kmreader-cover';
        while (entries.any((e) => e.getAttribute('id') == id)) {
          id += '-new';
        }
        path = p.posix.join(p.posix.dirname(safePackage), '$id.png');
        while (names.contains(path)) {
          path = p.posix.join(
            p.posix.dirname(path),
            'new-${p.posix.basename(path)}',
          );
        }
        entry = XmlElement(
          XmlName.parts('item', prefix: manifest.name.prefix),
          [
            XmlAttribute(XmlName.parts('id'), id),
            XmlAttribute(XmlName.parts('href'), p.posix.basename(path)),
            XmlAttribute(XmlName.parts('media-type'), 'image/png'),
          ],
        );
        manifest.children.add(entry);
        if (package.rootElement.getAttribute('version')?.startsWith('3') ==
            true) {
          entry.setAttribute('properties', 'cover-image');
        }
        if (oldMeta != null) {
          oldMeta.setAttribute('content', id);
        } else {
          metadata.children.add(
            XmlElement(XmlName.parts('meta', prefix: metadata.name.prefix), [
              XmlAttribute(XmlName.parts('name'), 'cover'),
              XmlAttribute(XmlName.parts('content'), id),
            ]),
          );
        }
      }
      replacements[path] = entry.getAttribute('media-type') == 'image/jpeg'
          ? img.encodeJpg(image, quality: 95)
          : img.encodePng(image);
    }
    for (final declaration in package.children.whereType<XmlDeclaration>()) {
      declaration.encoding = 'UTF-8';
    }
    replacements[safePackage] = utf8.encode(package.toXmlString());
    destination.parent.createSync(recursive: true);
    output = OutputFileStream(partial.path);
    final encoder = ZipEncoder()..startEncode(output);
    encoder.add(
      ArchiveFile.bytes('mimetype', utf8.encode('application/epub+zip'))
        ..compression = CompressionType.none,
    );
    for (final file in archive) {
      if (file.name == 'mimetype') continue;
      encoder.add(
        replacements.containsKey(file.name)
            ? ArchiveFile.bytes(file.name, replacements.remove(file.name)!)
            : file,
      );
    }
    for (final entry in replacements.entries) {
      encoder.add(ArchiveFile.bytes(entry.key, entry.value));
    }
    encoder.endEncode();
    output.closeSync();
    output = null;
    // Parse the generated copy before making it visible to the sender.
    EpubDocument.open(partial.path).close();
    if (destination.existsSync()) {
      throw const KindleFailure('management_source');
    }
    partial.renameSync(target);
  } on KindleFailure {
    rethrow;
  } catch (_) {
    throw const KindleFailure('management_source');
  } finally {
    output?.closeSync();
    input.closeSync();
    if (partial.existsSync()) partial.deleteSync();
  }
}
