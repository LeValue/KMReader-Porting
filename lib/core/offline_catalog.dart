import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'api.dart';
import 'models.dart';

/// Account-scoped metadata independent of the exact requests viewed online.
/// FTS searches metadata values, with all SQL values passed as parameters.
class OfflineCatalog {
  OfflineCatalog(this.db) {
    db.execute('''CREATE TABLE IF NOT EXISTS catalog_records(
      server TEXT NOT NULL,kind TEXT NOT NULL,id TEXT NOT NULL,value TEXT NOT NULL,
      search TEXT NOT NULL, UNIQUE(server,kind,id))''');
    db.execute(
      '''CREATE VIRTUAL TABLE IF NOT EXISTS catalog_search USING fts5(
      search,content='catalog_records',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2')''',
    );
    db.execute(
      '''CREATE TRIGGER IF NOT EXISTS catalog_insert AFTER INSERT ON catalog_records BEGIN
      INSERT INTO catalog_search(rowid,search) VALUES(new.rowid,new.search); END''',
    );
    db.execute(
      '''CREATE TRIGGER IF NOT EXISTS catalog_delete AFTER DELETE ON catalog_records BEGIN
      INSERT INTO catalog_search(catalog_search,rowid,search) VALUES('delete',old.rowid,old.search); END''',
    );
    db.execute(
      '''CREATE TRIGGER IF NOT EXISTS catalog_update AFTER UPDATE ON catalog_records BEGIN
      INSERT INTO catalog_search(catalog_search,rowid,search) VALUES('delete',old.rowid,old.search);
      INSERT INTO catalog_search(rowid,search) VALUES(new.rowid,new.search); END''',
    );
  }
  final Database db;
  void put(String server, CatalogItem item) {
    Iterable<String> strings(dynamic value) sync* {
      if (value is String) yield value;
      if (value is List) {
        for (final v in value) {
          yield* strings(v);
        }
      }
      if (value is Map) {
        for (final v in value.values) {
          yield* strings(v);
        }
      }
    }

    final search = [
      text(item.json['name']),
      text(item.json['seriesTitle']),
      ...strings(item.json['metadata']),
      text(item.json['summary']),
    ].join(' ');
    db.execute(
      '''INSERT INTO catalog_records(server,kind,id,value,search) VALUES(?,?,?,?,?)
      ON CONFLICT(server,kind,id) DO UPDATE SET value=excluded.value,search=excluded.search WHERE catalog_records.value!=excluded.value''',
      [server, item.kind, item.id, jsonEncode(item.json), search],
    );
  }

  void remove(String server, String kind, String id) => db.execute(
    'DELETE FROM catalog_records WHERE server=? AND kind=? AND id=?',
    [server, kind, id],
  );
  int count(String server, String kind) => integer(
    db.select(
      'SELECT count(*) AS n FROM catalog_records WHERE server=? AND kind=?',
      [server, kind],
    ).first['n'],
  );

  CatalogPage query(
    String server,
    String kind, {
    String? search,
    Json? condition,
    String? libraryId,
    String? path,
    int page = 0,
    int size = 40,
    String sort = 'metadata.titleSort,asc',
  }) {
    final sql = _OfflineSql(kind);
    final clauses = ['c.server=?', 'c.kind=?'];
    final args = <Object?>[server, kind];
    if (libraryId != null) {
      clauses.add("json_extract(c.value,'\$.libraryId')=?");
      args.add(libraryId);
    }
    if (condition != null) {
      clauses.add(sql.condition(condition));
      args.addAll(sql.args);
    }
    final terms = (search ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (terms.isNotEmpty) {
      // Unicode FTS treats CJK sentences as a single token; substring fallback
      // also makes searches in the middle of a CJK title work.
      if (RegExp(r'[\u3000-\u9fff\uac00-\ud7af]').hasMatch(search!)) {
        for (final term in terms) {
          clauses.add('instr(lower(c.search),lower(?))>0');
          args.add(term);
        }
      } else {
        clauses.add(
          'c.rowid IN (SELECT rowid FROM catalog_search WHERE catalog_search MATCH ?)',
        );
        args.add(
          terms.map((s) => '"${s.replaceAll('"', '""')}"*').join(' AND '),
        );
      }
    }
    if (path != null) {
      final match = RegExp(
        r'^/api/v1/(series|collections|readlists)/([^/]+)/(books|series)$',
      ).firstMatch(path);
      if (match != null) {
        final id = Uri.decodeComponent(match[2]!);
        if (match[1] == 'series' && kind == 'books') {
          clauses.add("json_extract(c.value,'\$.seriesId')=?");
          args.add(id);
        } else {
          final list = db.select(
            'SELECT value FROM catalog_records WHERE server=? AND kind=? AND id=?',
            [server, match[1], id],
          );
          final ids = list.isEmpty
              ? <dynamic>[]
              : (object(
                          jsonDecode(list.first['value'] as String),
                        )[kind == 'books' ? 'bookIds' : 'seriesIds']
                        as List? ??
                    []);
          if (ids.isEmpty) {
            clauses.add('0');
          } else {
            clauses.add('c.id IN (${List.filled(ids.length, '?').join(',')})');
            args.addAll(ids);
          }
        }
      } else if (path.endsWith('/books/ondeck')) {
        clauses.add("${sql.readStatus}='UNREAD'");
        clauses.add(
          "EXISTS(SELECT 1 FROM catalog_records r WHERE r.server=c.server AND r.kind='books' AND json_extract(r.value,'\$.seriesId')=json_extract(c.value,'\$.seriesId') AND json_extract(r.value,'\$.readProgress.completed')=1)",
        );
      } else if (!RegExp(r'^/api/v1/(books|series)/(list|new|updated)$')
          .hasMatch(path)) {
        throw const ApiFailure(
          'This list must be opened online before it can be used offline.',
          offline: true,
        );
      }
    }
    final where = clauses.join(' AND ');
    final from =
        'catalog_records c LEFT JOIN progress p ON p.server=c.server AND p.book=c.id AND c.kind=\'books\'';
    final total = integer(
      db
          .select('SELECT count(*) AS n FROM $from WHERE $where', args)
          .first['n'],
    );
    final order = <String>[];
    for (final part in serverSort(kind, sort)) {
      final pieces = part.split(',');
      final expression = sql.sortField(pieces.first);
      order.add('$expression ${pieces.last == 'desc' ? 'DESC' : 'ASC'}');
    }
    order.add('c.id ASC');
    size = size.clamp(1, 1000);
    page = page.clamp(0, 1 << 30);
    final records = db.select(
      'SELECT c.value FROM $from WHERE $where ORDER BY ${order.join(',')} LIMIT ? OFFSET ?',
      [...args, size, page * size],
    );
    return CatalogPage(
      records
          .map(
            (r) => CatalogItem(kind, object(jsonDecode(r['value'] as String))),
          )
          .toList(),
      (page + 1) * size >= total,
      total,
    );
  }
}

class _OfflineSql {
  _OfflineSql(this.kind);
  final String kind;
  final args = <Object?>[];
  String get readStatus {
    if (kind == 'series') {
      return "CASE WHEN coalesce(json_extract(c.value,'\$.booksReadCount'),0)>=coalesce(json_extract(c.value,'\$.booksCount'),1) THEN 'READ' WHEN coalesce(json_extract(c.value,'\$.booksInProgressCount'),0)>0 OR coalesce(json_extract(c.value,'\$.booksReadCount'),0)>0 THEN 'IN_PROGRESS' ELSE 'UNREAD' END";
    }
    const local =
        "CASE WHEN json_extract(p.value,'\$.reset')=1 THEN NULL WHEN json_extract(p.value,'\$.kind')='epub' THEN json_extract(c.value,'\$.readProgress') ELSE coalesce(json_extract(p.value,'\$'),json_extract(c.value,'\$.readProgress')) END";
    return "CASE WHEN json_extract($local,'\$.completed')=1 THEN 'READ' WHEN coalesce(json_extract($local,'\$.page'),0)>0 THEN 'IN_PROGRESS' ELSE 'UNREAD' END";
  }

  String field(String name) {
    final path = switch (name) {
      'title' => "coalesce(json_extract(c.value,'\$.metadata.title'),json_extract(c.value,'\$.name'),'')",
      'titleSort' => "coalesce(json_extract(c.value,'\$.metadata.titleSort'),json_extract(c.value,'\$.metadata.title'),json_extract(c.value,'\$.name'),'')",
      'readStatus' => readStatus,
      'seriesId' ||
      'libraryId' ||
      'deleted' => "json_extract(c.value,'\$.$name')",
      'oneShot' => "json_extract(c.value,'\$.oneshot')",
      'seriesStatus' => "json_extract(c.value,'\$.metadata.status')",
      'mediaProfile' => "json_extract(c.value,'\$.media.mediaProfile')",
      'mediaStatus' => "json_extract(c.value,'\$.media.status')",
      'ageRating' ||
      'numberSort' ||
      'releaseDate' ||
      'publisher' ||
      'language' ||
      'complete' => "json_extract(c.value,'\$.metadata.$name')",
      _ => throw ApiFailure(
        'This filter is unavailable offline: $name',
        offline: true,
      ),
    };
    return path;
  }

  String sortField(String name) {
    if (name == 'metadata.titleSort' || name == 'metadata.title') {
      return '${field(name.split('.').last)} COLLATE NOCASE';
    }
    if (name == 'metadata.numberSort') return field('numberSort');
    if (name == 'readProgress.readDate') {
      return "coalesce(json_extract(p.value,'\$.lastModified'),json_extract(c.value,'\$.readProgress.readDate'))";
    }
    if (RegExp(
      r'^(created|lastModified|fileSize|booksCount|booksReadCount|booksInProgressCount|name|url|metadata\.(releaseDate|publisher|ageRating)|media\.pagesCount)$',
    ).hasMatch(name)) {
      return "json_extract(c.value,'\$.$name')";
    }
    throw ApiFailure('This sort is unavailable offline: $name', offline: true);
  }

  String condition(Json value) {
    if (value.isEmpty) return '1';
    return value.entries
        .map((entry) {
          if (entry.key == 'allOf' || entry.key == 'anyOf') {
            final children = (entry.value as List)
                .map((v) => condition(object(v)))
                .toList();
            return children.isEmpty
                ? (entry.key == 'allOf' ? '1' : '0')
                : '(${children.join(entry.key == 'allOf' ? ' AND ' : ' OR ')})';
          }
          final name = entry.key,
              filter = object(entry.value),
              op = text(filter['operator']);
          final arrayPath = switch (name) {
            'author' => 'metadata.authors',
            'tag' => 'metadata.tags',
            'genre' => 'metadata.genres',
            'sharingLabel' => 'metadata.sharingLabels',
            'collectionId' => 'collectionIds',
            'readListId' => 'readListIds',
            _ => null,
          };
          var expression = arrayPath == null
              ? field(name)
              : name == 'author'
              ? "json_extract(a.value,'\$.name')"
              : 'a.value';
          final array = "json_each(c.value,'\$.$arrayPath') a";
          if (op == 'isNull' || op == 'isNotNull') {
            return arrayPath != null
                ? '${op == 'isNull' ? 'NOT ' : ''}EXISTS(SELECT 1 FROM $array)'
                : '$expression IS ${op == 'isNull' ? '' : 'NOT '}NULL';
          }
          if (op == 'isTrue' || op == 'isFalse') {
            return 'coalesce($expression,0)=${op == 'isTrue' ? 1 : 0}';
          }
          Object? target = name == 'author'
              ? object(filter['value'])['name']
              : filter['value'];
          String predicate;
          if (op == 'before' ||
              op == 'after' ||
              op == 'isInTheLast' ||
              op == 'isNotInTheLast') {
            target = filter['dateTime'];
            if (op == 'isInTheLast' || op == 'isNotInTheLast') {
              final days = RegExp(r'^P(\d+)D$')
                  .firstMatch(text(filter['duration']));
              if (days == null) {
                throw const ApiFailure(
                  'Unsupported offline duration.',
                  offline: true,
                );
              }
              target = DateTime.now()
                  .toUtc()
                  .subtract(Duration(days: int.parse(days[1]!)))
                  .toIso8601String();
            }
            args.add(target);
            predicate =
                'julianday($expression) ${op == 'before' || op == 'isNotInTheLast' ? '<' : '>'} julianday(?)';
          } else {
            switch (op) {
              case 'is':
              case 'isNot':
              case 'greaterThan':
              case 'lessThan':
                args.add(target);
                predicate =
                    '$expression ${switch (op) {
                      'is' => '=',
                      'isNot' => '!=',
                      'greaterThan' => '>',
                      _ => '<',
                    }} ? COLLATE NOCASE';
              case 'contains':
              case 'doesNotContain':
                args.add(target);
                predicate =
                    'instr(lower(coalesce($expression,\'\')),lower(?))${op == 'contains' ? '>0' : '=0'}';
              case 'beginsWith':
              case 'doesNotBeginWith':
              case 'endsWith':
              case 'doesNotEndWith':
                args.add(target);
                args.add(target);
                final beginning =
                    op == 'beginsWith' || op == 'doesNotBeginWith';
                predicate =
                    'substr(lower(coalesce($expression,\'\')),${beginning ? '1' : '-length(?)'},${beginning ? 'length(?)' : 'length(?)'}) ${op.startsWith('doesNot') ? '!=' : '='} lower(?)';
                // Two copies select the prefix/suffix length and compare its value.
                if (!beginning) args.add(target);
              default:
                throw ApiFailure(
                  'Unsupported offline operator: $op',
                  offline: true,
                );
            }
          }
          if (arrayPath != null) {
            if (op == 'isNot') {
              predicate = predicate.replaceFirst('!=', '=');
              return 'NOT EXISTS(SELECT 1 FROM $array WHERE $predicate)';
            }
            return 'EXISTS(SELECT 1 FROM $array WHERE $predicate)';
          }
          return '($predicate)';
        })
        .join(' AND ');
  }
}
