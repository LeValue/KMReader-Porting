import 'dart:isolate';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import '../../features/reader/epub_document.dart';
import '../models.dart';
import 'client.dart';
import 'positions.dart';

/// Relocates verified original-Kindle positions by exact Unicode text. Changed
/// or ambiguous passages fail closed; equal percentages are not equal places.
class KindleEditionMigration {
  KindleEditionMigration._(this.oldMap, this.newMap, this.source, this.target);
  final KindlePositionMap oldMap, newMap;
  final Json source, target;

  static Future<KindleEditionMigration> open(
    String source,
    String target,
  ) async {
    final oldMap = await KindlePositionMap.open(source);
    final newMap = await KindlePositionMap.open(target);
    if (oldMap == null || newMap == null || newMap.primary == null) {
      throw const KindleFailure('management_mapping_unavailable');
    }
    final inspected = await Isolate.run(
      () =>
          (_inspect(source, oldMap.entries), _inspect(target, newMap.entries)),
    );
    return KindleEditionMigration._(oldMap, newMap, inspected.$1, inspected.$2);
  }

  static Json _inspect(String path, List<Json> entries) {
    final document = EpubDocument.open(path);
    try {
      final container = XmlDocument.parse(
        EpubDocument.decodeText(document.resource('META-INF/container.xml')),
      );
      final package = container.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'rootfile')
          .getAttribute('full-path')!;
      final anchors = <Json>[];
      final pages = <String, dom.Document>{};
      var characters = 0;
      for (final entry in entries) {
        final path = EpubDocument.resolve(package, text(entry['href']));
        final page = pages.putIfAbsent(
          path,
          () => html.parse(EpubDocument.decodeText(document.resource(path))),
        );
        final element = page.getElementById(text(entry['id']));
        if (element == null || element.text.runes.length != entry['length']) {
          continue;
        }
        characters += element.text.length;
        if (characters > 32 * 1024 * 1024) {
          throw const KindleFailure('management_mapping_size');
        }
        anchors.add({...entry, 'text': element.text, 'path': path});
      }
      return {
        'anchors': anchors,
        'chapters': document.chapters.map((c) => c.path).toList(),
        // Only marked chapters are needed to resolve local CFI text boundaries.
        'pages': {
          for (final entry in pages.entries) entry.key: entry.value.outerHtml,
        },
      };
    } finally {
      document.close();
    }
  }

  List<Json> get _old => (source['anchors'] as List).map(object).toList();
  List<Json> get _new => (target['anchors'] as List).map(object).toList();

  int position(int original) {
    final candidates =
        _old
            .where(
              (a) =>
                  integer(a['position']) <= original &&
                  original < integer(a['position']) + integer(a['length']),
            )
            .toList()
          ..sort(
            (a, b) => integer(a['length']).compareTo(integer(b['length'])),
          );
    for (final anchor in candidates) {
      final matches = _new.where((a) => a['text'] == anchor['text']).toList();
      final positions = matches.map((a) => integer(a['position'])).toSet();
      if (positions.length != 1) continue;
      return positions.single + original - integer(anchor['position']);
    }
    throw const KindleFailure('management_mapping_ambiguous');
  }

  Json locator(int original) {
    final found = newMap.locator(position(original));
    if (found == null) {
      throw const KindleFailure('management_mapping_ambiguous');
    }
    return found;
  }

  /// Resolve the CFI produced by the reader against the original DOM. Only
  /// structurally verified point CFIs are accepted; ranges/temporal CFIs stop
  /// migration rather than silently retaining an invalid old-edition CFI.
  int cfiPosition(String cfi) {
    final match = RegExp(r'^epubcfi\(/6/([0-9]+)(?:\[[^\]^]*\])?!(/[^,~@]+)\)$')
        .firstMatch(cfi);
    if (match == null) throw const KindleFailure('management_local_locator');
    final spine = int.parse(match.group(1)!);
    final chapters = (source['chapters'] as List).cast<String>();
    final index = spine ~/ 2 - 1;
    if (spine.isOdd || index < 0 || index >= chapters.length) {
      throw const KindleFailure('management_local_locator');
    }
    final path = chapters[index];
    final encoded = object(source['pages'])[path];
    if (encoded is! String) {
      throw const KindleFailure('management_local_locator');
    }
    final page = html.parse(encoded);
    dom.Node current = page.documentElement!;
    final steps = match.group(2)!.substring(1).split('/');
    var utf16Offset = 0;
    for (var i = 0; i < steps.length; i++) {
      final step = RegExp(
        r'^([0-9]+)(?:\[([A-Za-z0-9_.:-]+)\])?(?::([0-9]+)(?:;s=[ab])?)?$',
      ).firstMatch(steps[i]);
      if (step == null || current is! dom.Element) {
        throw const KindleFailure('management_local_locator');
      }
      final number = int.parse(step.group(1)!);
      if (number < 1 || step.group(3) != null && i != steps.length - 1) {
        throw const KindleFailure('management_local_locator');
      }
      if (number.isEven) {
        final child = number ~/ 2 - 1;
        if (child >= current.children.length) {
          throw const KindleFailure('management_local_locator');
        }
        current = current.children[child];
        if (step.group(2) != null &&
            current.id != step.group(2)) {
          throw const KindleFailure('management_local_locator');
        }
      } else {
        // Odd CFI indices identify a text run between adjacent elements.
        var slot = 1;
        final nodes = <dom.Text>[];
        for (final node in current.nodes) {
          if (node is dom.Element) {
            slot += 2;
          }
          if (node is dom.Text && slot == number) nodes.add(node);
        }
        if (nodes.length != 1 || i != steps.length - 1) {
          throw const KindleFailure('management_local_locator');
        }
        current = nodes.single;
      }
      utf16Offset = int.tryParse(step.group(3) ?? '0') ?? 0;
    }
    if (current is! dom.Text ||
        utf16Offset > current.data.length ||
        utf16Offset > 0 &&
            utf16Offset < current.data.length &&
            current.data.codeUnitAt(utf16Offset - 1) >= 0xd800 &&
            current.data.codeUnitAt(utf16Offset - 1) <= 0xdbff) {
      throw const KindleFailure('management_local_locator');
    }
    var characters = current.data.substring(0, utf16Offset).runes.length;
    dom.Node node = current;
    while (node.parentNode is dom.Element) {
      final parent = node.parentNode! as dom.Element;
      for (final sibling in parent.nodes) {
        if (identical(sibling, node)) break;
        if (sibling is dom.Text) characters += sibling.data.runes.length;
        if (sibling is dom.Element) characters += sibling.text.runes.length;
      }
      final anchors = _old
          .where(
            (a) =>
                a['path'] == path &&
                a['id'] == parent.id &&
                parent.text == a['text'] &&
                characters < integer(a['length']),
          )
          .toList();
      if (anchors.length == 1) {
        return integer(anchors.single['position']) + characters;
      }
      node = parent;
    }
    throw const KindleFailure('management_local_locator');
  }

  List<Json> bookmarks(List<Json> originals) => originals.map((mark) {
    final original = mark['kindlePosition'] is int
        ? mark['kindlePosition'] as int
        : cfiPosition(text(mark['cfi']));
    final mapped = locator(original);
    return {
      ...mark,
      'id': text(mark['id'], 'migrated:${kindleRandom(12)}'),
      'cfi': '',
      'href': mapped['href'],
      'locator': mapped,
      'kindlePosition': position(original),
    };
  }).toList();
}
