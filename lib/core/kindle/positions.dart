import 'dart:convert';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models.dart';
import '../../features/reader/epub_document.dart';

DateTime? kindleTimestamp(dynamic value) {
  if (value is num) {
    if (!value.isFinite || value.abs() > 8640000000000) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (value > 100000000000 ? value : value * 1000).round(),
      isUtc: true,
    );
  }
  if (value is String) {
    final numeric = num.tryParse(value);
    if (numeric != null) return kindleTimestamp(numeric);
    return DateTime.tryParse(value)?.toUtc();
  }
  return null;
}

Json? kindleLastRead(Json sidecar) {
  final raw = sidecar['records'];
  if (raw is! List) return null;
  final records = raw.map(object).toList();
  for (final type in ['kindle.most_recent_read', 'kindle.lpr']) {
    final found = records.where((record) => record['type'] == type).firstOrNull;
    final position = num.tryParse('${found?['location']}');
    if (found != null &&
        position != null &&
        position.isFinite &&
        position >= 0 &&
        position == position.roundToDouble()) {
      return {
        'position': position.toInt(),
        'time': kindleTimestamp(
          found['creationTime'] ?? found['lastModificationTime'],
        )?.toIso8601String(),
      };
    }
  }
  return null;
}

class KindlePositionMap {
  KindlePositionMap(this.entries, this.acrs);
  final List<Json> entries;
  final Set<String> acrs;
  static Future<KindlePositionMap?> open(String path) =>
      Isolate.run(() => _open(path));
  static KindlePositionMap? _open(String path) {
    EpubDocument? document;
    try {
      document = EpubDocument.open(path);
      final bytes = document.resource('META-INF/kmreader-kindle.json');
      if (bytes.length > 16 * 1024 * 1024) return null;
      final metadata = object(jsonDecode(utf8.decode(bytes)));
      if (metadata['schema'] != 1 ||
          metadata['position_units'] != 'unicode_scalars' ||
          metadata['entries'] is! List) {
        return null;
      }
      final raw = metadata['entries'] as List;
      if (raw.length > 100000) return null;
      final container = XmlDocument.parse(
        EpubDocument.decodeText(document.resource('META-INF/container.xml')),
      );
      final package = container.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'rootfile')
          .getAttribute('full-path')!;
      final entries = <Json>[];
      for (final value in raw.map(object)) {
        final target = text(value['path']), id = text(value['id']);
        final position = value['position'], length = value['length'];
        if (target.isEmpty ||
            target.startsWith('/') ||
            target.contains('\\') ||
            target.split('/').contains('..') ||
            id.isEmpty ||
            id.length > 512 ||
            position is! int ||
            position < 0 ||
            length is! int ||
            length < 1) {
          continue;
        }
        entries.add({
          'href': p.posix.relative(target, from: p.posix.dirname(package)),
          'id': id,
          'position': position,
          'length': length,
        });
      }
      entries.sort(
        (a, b) => integer(a['position']).compareTo(integer(b['position'])),
      );
      return KindlePositionMap(
        entries,
        (metadata['container_acrs'] as List? ?? []).whereType<String>().toSet(),
      );
    } catch (_) {
      return null;
    } finally {
      document?.close();
    }
  }

  bool matches(Json sidecar) =>
      text(sidecar['acr']).isNotEmpty && acrs.contains(text(sidecar['acr']));
  Json? locator(int position) {
    // Overlapping parent/child spans can both be correct. Prefer the shortest
    // verified range containing the position, preserving its precise offset.
    Json? best;
    for (final entry in entries) {
      final start = integer(entry['position']),
          length = integer(entry['length']);
      if (start > position) break;
      if (position < start + length &&
          (best == null || length < integer(best['length']))) {
        best = entry;
      }
    }
    return best == null
        ? null
        : {...best, 'offset': position - integer(best['position'])};
  }
}
