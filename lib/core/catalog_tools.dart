import 'dart:convert';
import 'dart:math';

import 'api.dart';
import 'models.dart';
import 'repository.dart';

const filterLabels = <String, String>{
  'title': 'Title',
  'titleSort': 'Sort Title',
  'readStatus': 'Read Status',
  'libraryId': 'Library',
  'author': 'Author',
  'tag': 'Tag',
  'genre': 'Genre',
  'publisher': 'Publisher',
  'language': 'Language',
  'seriesStatus': 'Status',
  'ageRating': 'Age Rating',
  'releaseDate': 'Release Date',
  'numberSort': 'Number',
  'mediaProfile': 'Format',
  'mediaStatus': 'Media Status',
  'deleted': 'Deleted',
  'oneShot': 'One Shot',
  'complete': 'Complete',
  'sharingLabel': 'Sharing Label',
  'seriesId': 'Series',
  'collectionId': 'Collection',
  'readListId': 'Read List',
};
const filterEnums = <String, List<String>>{
  'readStatus': ['UNREAD', 'IN_PROGRESS', 'READ'],
  'seriesStatus': ['ONGOING', 'ENDED', 'ABANDONED', 'HIATUS'],
  'mediaProfile': ['DIVINA', 'PDF', 'EPUB'],
  'mediaStatus': ['UNKNOWN', 'ERROR', 'READY', 'UNSUPPORTED', 'OUTDATED'],
  'deleted': ['true', 'false'],
  'oneShot': ['true', 'false'],
  'complete': ['true', 'false'],
};
List<String> filterFields(String kind) => [
  'title',
  'readStatus',
  'libraryId',
  'author',
  'tag',
  'releaseDate',
  'deleted',
  'oneShot',
  if (kind == 'books') ...[
    'seriesId',
    'readListId',
    'numberSort',
    'mediaProfile',
    'mediaStatus',
  ] else ...[
    'titleSort',
    'genre',
    'publisher',
    'language',
    'seriesStatus',
    'ageRating',
    'complete',
    'sharingLabel',
    'collectionId',
  ],
];
List<String> filterOperators(String field) {
  if (['deleted', 'oneShot', 'complete'].contains(field)) {
    return ['isTrue', 'isFalse'];
  }
  if (field == 'title' || field == 'titleSort') {
    return [
      'contains',
      'doesNotContain',
      'is',
      'isNot',
      'beginsWith',
      'endsWith',
      'doesNotBeginWith',
      'doesNotEndWith',
    ];
  }
  if (field == 'releaseDate') {
    return [
      'after',
      'before',
      'isInTheLast',
      'isNotInTheLast',
      'isNull',
      'isNotNull',
    ];
  }
  if (field == 'numberSort' || field == 'ageRating') {
    return [
      'is',
      'isNot',
      'greaterThan',
      'lessThan',
      if (field == 'ageRating') ...['isNull', 'isNotNull'],
    ];
  }
  return [
    'is',
    'isNot',
    if (['tag', 'genre', 'sharingLabel'].contains(field)) ...[
      'isNull',
      'isNotNull',
    ],
  ];
}

class CatalogFilter {
  CatalogFilter({this.any = false, List<Json>? entries})
    : entries = entries ?? [];
  final bool any;
  final List<Json> entries;
  factory CatalogFilter.fromJson(Json data) => CatalogFilter(
    any: data['any'] == true,
    entries: (data['entries'] as List? ?? []).map(object).toList(),
  );
  Json toJson() => {'any': any, 'entries': entries};
  factory CatalogFilter.fromCondition(Json? condition, String kind) {
    if (condition == null || condition.isEmpty) return CatalogFilter();
    Json decode(Json node) {
      for (final group in ['allOf', 'anyOf']) {
        if (node.length == 1 && node[group] is List) {
          if ((node[group] as List).isEmpty) return {'raw': node};
          return {
            'any': group == 'anyOf',
            'entries': (node[group] as List)
                .map((v) => decode(object(v)))
                .toList(),
          };
        }
      }
      if (node.length != 1) return {'raw': node};
      final field = node.keys.single,
          value = object(node.values.single),
          op = text(object(node.values.single)['operator']);
      if (!filterFields(kind).contains(field) ||
          !filterOperators(field).contains(op)) {
        return {'raw': node};
      }
      if (value.keys.any(
        (key) => !{'operator', 'value', 'dateTime', 'duration'}.contains(key),
      )) {
        return {'raw': node};
      }
      dynamic raw = value['value'];
      if (field == 'author') {
        final author = object(raw);
        if (author.keys.any((k) => k != 'name')) return {'raw': node};
        raw = author['name'];
      }
      if (field == 'releaseDate' && ['before', 'after'].contains(op)) {
        final date = DateTime.tryParse(text(value['dateTime']));
        if (date == null ||
            date.hour != 0 ||
            date.minute != 0 ||
            date.second != 0 ||
            date.millisecond != 0 ||
            date.microsecond != 0) {
          return {'raw': node};
        }
        raw = date.toIso8601String().substring(0, 10);
      } else if (field == 'releaseDate' &&
          ['isInTheLast', 'isNotInTheLast'].contains(op)) {
        final duration = RegExp(r'^P(\d+)D$')
            .firstMatch(text(value['duration']));
        if (duration == null) return {'raw': node};
        raw = duration[1];
      }
      return {'field': field, 'operator': op, if (raw != null) 'value': '$raw'};
    }

    final root = decode(condition);
    return root.containsKey('entries')
        ? CatalogFilter.fromJson(root)
        : CatalogFilter(entries: [root]);
  }
  Json? condition(String kind) {
    final conditions = <Json>[];
    for (final row in entries) {
      if (row['raw'] is Map) {
        conditions.add(object(row['raw']));
        continue;
      }
      if (row.containsKey('entries')) {
        final child = CatalogFilter.fromJson(row).condition(kind);
        if (child != null) conditions.add(child);
        continue;
      }
      final field = text(row['field']);
      final operator = text(row['operator'], 'is');
      if (!filterFields(kind).contains(field) ||
          !filterOperators(field).contains(operator)) {
        throw const FormatException('Invalid filter.');
      }
      final raw = text(row['value']).trim();
      final value = <String, dynamic>{'operator': operator};
      if (!['isNull', 'isNotNull', 'isTrue', 'isFalse'].contains(operator)) {
        if (raw.isEmpty) throw const FormatException('Enter a filter value.');
        if (field == 'numberSort' || field == 'ageRating') {
          final number = num.tryParse(raw);
          if (number == null ||
              !number.isFinite ||
              field == 'ageRating' && number != number.round()) {
            throw const FormatException('Enter a valid number.');
          }
          value['value'] = field == 'ageRating' ? number.toInt() : number;
        } else if (field == 'releaseDate') {
          if (operator == 'after' || operator == 'before') {
            final date = DateTime.tryParse(raw);
            if (date == null ||
                date.toIso8601String().substring(0, 10) != raw) {
              throw const FormatException('Use a valid YYYY-MM-DD date.');
            }
            value['dateTime'] = DateTime.utc(
              date.year,
              date.month,
              date.day,
            ).toIso8601String();
          } else {
            final days = int.tryParse(raw);
            if (days == null || days < 1) {
              throw const FormatException('Enter a positive number of days.');
            }
            value['duration'] = 'P${days}D';
          }
        } else if (field == 'author') {
          value['value'] = {'name': raw};
        } else if (['deleted', 'oneShot', 'complete'].contains(field)) {
          if (!['true', 'false'].contains(raw)) {
            throw const FormatException('Choose true or false.');
          }
          value['value'] = raw == 'true';
        } else {
          if (filterEnums[field] != null &&
              !filterEnums[field]!.contains(raw)) {
            throw const FormatException('Choose a valid filter value.');
          }
          value['value'] = raw;
        }
      }
      conditions.add({field: value});
    }
    return combineConditions(conditions, any: any);
  }
}

Json? combineConditions(Iterable<Json?> conditions, {bool any = false}) {
  final values = conditions.whereType<Json>().toList();
  return values.isEmpty
      ? null
      : values.length == 1
      ? values.single
      : {any ? 'anyOf' : 'allOf': values};
}

class FilterPreset {
  FilterPreset({
    required this.id,
    required this.name,
    required this.kind,
    required this.filter,
    this.search = '',
    this.sort = 'metadata.titleSort,asc',
    this.smart = false,
  });
  final String id, name, kind, search, sort;
  final CatalogFilter filter;
  final bool smart;
  factory FilterPreset.create(
    String name,
    String kind,
    CatalogFilter filter, {
    String search = '',
    String sort = 'metadata.titleSort,asc',
    bool smart = false,
  }) => FilterPreset(
    id: '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
    name: name,
    kind: kind,
    filter: filter,
    search: search,
    sort: sort,
    smart: smart,
  );
  factory FilterPreset.fromJson(Json data) => FilterPreset(
    id: text(data['id']),
    name: text(data['name']),
    kind: text(data['kind'], 'books'),
    filter: CatalogFilter.fromJson(object(data['filter'])),
    search: text(data['search']),
    sort: text(data['sort'], 'metadata.titleSort,asc'),
    smart: data['smart'] == true,
  );
  Json toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'filter': filter.toJson(),
    'search': search,
    'sort': sort,
    'smart': smart,
  };
}

class CatalogTools {
  CatalogTools(this.repository);
  final Repository repository;
  String get _presetKey => 'filters:${repository.profile.id}';
  List<FilterPreset> get presets =>
      (repository.store.setting<List<dynamic>>(_presetKey) ?? [])
          .map((v) => FilterPreset.fromJson(object(v)))
          .toList();
  void savePreset(FilterPreset value) {
    final all = presets.where((p) => p.id != value.id).toList()..add(value);
    repository.store.setSetting(
      _presetKey,
      all.map((p) => p.toJson()).toList(),
    );
    repository.localCatalogChanged();
  }

  void deletePreset(String id) {
    repository.store.setSetting(
      _presetKey,
      presets.where((p) => p.id != id).map((p) => p.toJson()).toList(),
    );
    repository.store.setSetting(
      'pinned:presets:${repository.profile.id}',
      pinned('presets')..remove(id),
    );
    repository.localCatalogChanged();
  }

  List<String> pinned(String kind) =>
      (repository.store.setting<List<dynamic>>(
                'pinned:$kind:${repository.profile.id}',
              ) ??
              [])
          .whereType<String>()
          .toList();
  void pin(String kind, String id) {
    final ids = pinned(kind);
    if (!ids.remove(id)) ids.add(id);
    repository.store.setSetting('pinned:$kind:${repository.profile.id}', ids);
    repository.localCatalogChanged();
  }

  Future<List<CatalogItem>> all(
    String kind, {
    String? path,
    Json? condition,
  }) async {
    final result = <CatalogItem>[];
    for (var page = 0; ; page++) {
      if (repository.closed) {
        throw const ApiFailure('The server connection was closed.');
      }
      final chunk = await repository.catalog(
        kind,
        path: path,
        condition: condition,
        page: page,
      );
      result.addAll(chunk.items);
      if (chunk.last || chunk.items.isEmpty) return result;
    }
  }

  Future<void> updateMetadata(
    String kind,
    String id,
    Json patch, {
    Json? original,
  }) async {
    _admin();
    if (patch.isEmpty) return;
    if (original != null) {
      final current = object(
        object(
          await repository.api.request(
            '/api/v1/$kind/${Uri.encodeComponent(id)}',
          ),
        )['metadata'],
      );
      for (final key in patch.keys) {
        final before = key.endsWith('Lock')
            ? original[key] == true
            : original[key];
        final now = key.endsWith('Lock') ? current[key] == true : current[key];
        if (jsonEncode(before) != jsonEncode(now)) {
          throw const ApiFailure(
            'These metadata changed on another device. Reload before saving.',
          );
        }
      }
    }
    await repository.api.request(
      '/api/v1/$kind/${Uri.encodeComponent(id)}/metadata',
      method: 'PATCH',
      body: patch,
    );
    if (repository.closed) return;
    Json? value;
    try {
      value = object(
        await repository.api.request(
          '/api/v1/$kind/${Uri.encodeComponent(id)}',
        ),
      );
    } on ApiFailure {
      /* The PATCH succeeded; a failed refresh must not report a failed edit. */
    }
    if (value != null) repository.rememberItem(CatalogItem(kind, value));
    repository.refreshContent();
  }

  Future<Json> list(String kind, String id) async => object(
    await repository.api.request('/api/v1/$kind/${Uri.encodeComponent(id)}'),
  );
  Future<void> updateList(
    String kind,
    String id,
    Json original,
    Json patch,
  ) async {
    _admin();
    final latest = await list(kind, id);
    for (final key in patch.keys) {
      if (jsonEncode(original[key]) != jsonEncode(latest[key])) {
        throw const ApiFailure(
          'This list changed on another device. Reload it before saving.',
        );
      }
    }
    final idsKey = kind == 'readlists' ? 'bookIds' : 'seriesIds';
    if (patch.containsKey(idsKey) && (patch[idsKey] as List).isEmpty) {
      throw const FormatException('A list must contain at least one item.');
    }
    await repository.api.request(
      '/api/v1/$kind/${Uri.encodeComponent(id)}',
      method: 'PATCH',
      body: patch,
    );
    repository.rememberItem(CatalogItem(kind, {...latest, ...patch}));
    repository.refreshContent();
  }

  Future<void> deleteList(String kind, String id) async {
    _admin();
    await repository.api.request(
      '/api/v1/$kind/${Uri.encodeComponent(id)}',
      method: 'DELETE',
    );
    final pins = pinned(kind)..remove(id);
    repository.store.setSetting('pinned:$kind:${repository.profile.id}', pins);
    repository.removeCatalogItem(kind, id);
  }

  Future<void> batchProgress(List<CatalogItem> items, bool read) async {
    final books = <String, Book>{};
    for (final item in items) {
      if (item.kind == 'books') {
        books[item.id] = item.book;
      } else if (item.kind == 'series') {
        final children = await all(
          'books',
          condition: {
            'seriesId': {'operator': 'is', 'value': item.id},
          },
        );
        for (final child in children) {
          books[child.id] = child.book;
        }
      }
    }
    repository.markBooks(books.values, read);
  }

  Future<void> batchDownload(List<CatalogItem> items) async {
    final books = <String, Book>{};
    for (final item in items) {
      if (item.kind == 'books') {
        books[item.id] = item.book;
      } else if (item.kind == 'series') {
        final children = await all(
          'books',
          condition: {
            'seriesId': {'operator': 'is', 'value': item.id},
          },
        );
        for (final child in children) {
          books[child.id] = child.book;
        }
      }
    }
    await Future.wait(books.values.map(repository.download));
  }

  void _admin() {
    if (!repository.profile.admin) {
      throw const ApiFailure('Admin access required.', status: 403);
    }
    if (repository.offline) {
      throw const ApiFailure(
        'Reconnect to edit server content.',
        offline: true,
      );
    }
  }
}
