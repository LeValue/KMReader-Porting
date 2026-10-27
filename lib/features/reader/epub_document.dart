import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;

class EpubChapter {
  EpubChapter(this.path, this.title);
  final String path, title;
}

class EpubLocation {
  const EpubLocation(this.path, {this.fragment = ''});
  final String path, fragment;
}

class EpubNavigationEntry {
  const EpubNavigationEntry(
    this.title,
    this.location, [
    this.children = const [],
  ]);
  final String title;
  final EpubLocation? location;
  final List<EpubNavigationEntry> children;
}

class EpubDocument {
  EpubDocument._(
    this._input,
    this.archive,
    this.chapters,
    this.title,
    this.tableOfContents,
  );
  final InputFileStream _input;
  final Archive archive;
  final List<EpubChapter> chapters;
  final String title;
  final List<EpubNavigationEntry> tableOfContents;

  static String resolve(String from, String href) => locate(from, href).path;

  static EpubLocation locate(String from, String href) {
    final uri = Uri.parse(href);
    final path = Uri.decodeComponent(uri.path);
    if (uri.hasScheme || uri.hasAuthority || path.startsWith('/')) {
      throw const FormatException('Invalid EPUB resource path.');
    }
    final result = p.posix.normalize(
      path.isEmpty ? from : p.posix.join(p.posix.dirname(from), path),
    );
    if (result == '..' ||
        result == '.' ||
        result.startsWith('../') ||
        p.posix.isAbsolute(result) ||
        result.contains('\\') ||
        result.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('Invalid EPUB resource path.');
    }
    return EpubLocation(result, fragment: Uri.decodeComponent(uri.fragment));
  }

  static EpubDocument open(String file) {
    final input = InputFileStream(file);
    try {
      final archive = ZipDecoder().decodeStream(input, verify: true);
      String read(String name) {
        final item = archive.findFile(name);
        if (item == null || item.size > 32 * 1024 * 1024) {
          throw const FormatException('Missing or oversized EPUB document.');
        }
        return utf8.decode(item.content);
      }

      final container = XmlDocument.parse(read('META-INF/container.xml'));
      final packagePath = container.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'rootfile')
          .getAttribute('full-path');
      if (packagePath == null) {
        throw const FormatException('Invalid EPUB container.');
      }
      // Resolve from the archive root, not from META-INF/container.xml.
      final safePackagePath = resolve('container.xml', packagePath);
      final package = XmlDocument.parse(read(safePackagePath));
      final elements = package.descendants.whereType<XmlElement>().toList();
      final manifest = <String, String>{
        for (final e in elements.where((e) => e.name.local == 'item'))
          if (e.getAttribute('id') != null && e.getAttribute('href') != null)
            e.getAttribute('id')!: resolve(
              safePackagePath,
              e.getAttribute('href')!,
            ),
      };
      final title =
          elements
              .where((e) => e.name.local == 'title')
              .firstOrNull
              ?.innerText ??
          'EPUB';
      final chapters = <EpubChapter>[];
      for (final e in elements.where(
        (e) => e.name.local == 'itemref' && e.getAttribute('linear') != 'no',
      )) {
        final href = manifest[e.getAttribute('idref')];
        if (href == null) continue;
        final heading = html
            .parse(read(href))
            .querySelector('h1,h2,title')
            ?.text
            .trim();
        chapters.add(
          EpubChapter(
            href,
            heading == null || heading.isEmpty
                ? '${chapters.length + 1}'
                : heading,
          ),
        );
      }
      if (chapters.isEmpty) {
        throw const FormatException('This EPUB contains no readable chapters.');
      }
      final contents = _navigation(elements, manifest, chapters, read);
      return EpubDocument._(input, archive, chapters, title, contents);
    } catch (_) {
      input.closeSync();
      rethrow;
    }
  }

  static List<EpubNavigationEntry> _navigation(
    List<XmlElement> elements,
    Map<String, String> manifest,
    List<EpubChapter> chapters,
    String Function(String) read,
  ) {
    final chapterPaths = chapters.map((c) => c.path).toSet();
    EpubLocation? target(String from, String? href) {
      if (href == null) return null;
      try {
        final location = locate(from, href);
        return chapterPaths.contains(location.path) ? location : null;
      } on FormatException {
        return null;
      }
    }

    String label(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();
    bool isContents(dom.Element node) {
      if ((node.attributes['role'] ?? '')
          .split(RegExp(r'\s+'))
          .contains('doc-toc')) {
        return true;
      }
      for (final attribute in node.attributes.entries) {
        final name = attribute.key.toString();
        if (!name.endsWith(':type') ||
            !attribute.value.split(RegExp(r'\s+')).contains('toc')) {
          continue;
        }
        final prefix = name.substring(0, name.length - 5);
        for (
          dom.Element? ancestor = node;
          ancestor != null;
          ancestor = ancestor.parent
        ) {
          final namespace = ancestor.attributes['xmlns:$prefix'];
          if (namespace != null) {
            return namespace == 'http://www.idpf.org/2007/ops';
          }
        }
      }
      return false;
    }

    final nav = elements
        .where((e) => e.name.local == 'item')
        .where(
          (e) => (e.getAttribute('properties') ?? '')
              .split(RegExp(r'\s+'))
              .contains('nav'),
        )
        .firstOrNull;
    final navPath = manifest[nav?.getAttribute('id')];
    if (navPath != null) {
      try {
        final document = html.parse(read(navPath));
        final toc = document
            .querySelectorAll('nav')
            .where(isContents)
            .firstOrNull;
        var count = 0;
        List<EpubNavigationEntry> entries(dom.Element? list, int depth) {
          if (list == null || depth > 64) return [];
          final result = <EpubNavigationEntry>[];
          for (final item in list.children.where((e) => e.localName == 'li')) {
            if (++count > 10000) break;
            final heading = item.children
                .where((e) => e.localName == 'a' || e.localName == 'span')
                .firstOrNull;
            final children = entries(
              item.children.where((e) => e.localName == 'ol').firstOrNull,
              depth + 1,
            );
            final location = target(navPath, heading?.attributes['href']);
            final title = label(heading?.text ?? '');
            if (title.isNotEmpty && (location != null || children.isNotEmpty)) {
              result.add(EpubNavigationEntry(title, location, children));
            } else {
              result.addAll(children);
            }
          }
          return result;
        }

        final result = entries(
          toc?.children.where((e) => e.localName == 'ol').firstOrNull,
          0,
        );
        if (result.isNotEmpty) return result;
      } on FormatException {
        // A damaged optional index must not prevent reading the spine.
      }
    }

    final spine = elements.where((e) => e.name.local == 'spine').firstOrNull;
    final ncx = elements
        .where(
          (e) =>
              e.name.local == 'item' &&
              e.getAttribute('media-type') == 'application/x-dtbncx+xml',
        )
        .firstOrNull;
    final ncxPath =
        manifest[spine?.getAttribute('toc')] ??
        manifest[ncx?.getAttribute('id')];
    if (ncxPath != null) {
      try {
        final document = XmlDocument.parse(read(ncxPath));
        final map = document.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'navMap')
            .firstOrNull;
        var count = 0;
        List<EpubNavigationEntry> entries(XmlElement? parent, int depth) {
          if (parent == null || depth > 64) return [];
          final result = <EpubNavigationEntry>[];
          for (final point in parent.childElements.where(
            (e) => e.name.local == 'navPoint',
          )) {
            if (++count > 10000) break;
            final title = label(
              point.childElements
                      .where((e) => e.name.local == 'navLabel')
                      .firstOrNull
                      ?.innerText ??
                  '',
            );
            final href = point.childElements
                .where((e) => e.name.local == 'content')
                .firstOrNull
                ?.getAttribute('src');
            final location = target(ncxPath, href);
            final children = entries(point, depth + 1);
            if (title.isNotEmpty && (location != null || children.isNotEmpty)) {
              result.add(EpubNavigationEntry(title, location, children));
            } else {
              result.addAll(children);
            }
          }
          return result;
        }

        final result = entries(map, 0);
        if (result.isNotEmpty) return result;
      } on FormatException {
        // EPUB 2 navigation is optional when the spine is usable.
      }
    }
    return [
      for (final c in chapters)
        EpubNavigationEntry(c.title, EpubLocation(c.path)),
    ];
  }

  Uint8List resource(String path) {
    final item = archive.findFile(path);
    if (item == null || item.size > 64 * 1024 * 1024) {
      throw const FormatException('EPUB resource unavailable.');
    }
    return item.content;
  }

  String chapter(int index) => utf8.decode(resource(chapters[index].path));
  void close() => _input.closeSync();
}
