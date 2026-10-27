import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'repository.dart';
import 'catalog_tools.dart';

/// The upstream extended endpoints are optional. Only 404 establishes that a
/// server doesn't implement them; authentication and server errors propagate.
class ReadingStats {
  ReadingStats(this.repository);
  final Repository repository;
  Future<Json> load({String? libraryId}) async {
    final store = repository.store, server = repository.profile.id;
    final capability = 'readingStatsCapability:$server';
    final key = 'readingStats:${libraryId ?? "all"}';
    final unsupported = store.setting<int>(capability);
    if (!repository.offline &&
        (unsupported == null ||
            DateTime.now().millisecondsSinceEpoch - unsupported >=
                const Duration(days: 1).inMilliseconds)) {
      try {
        final query = <String, dynamic>{'libraryId': ?libraryId};
        // Sequential probing avoids sending two more unsupported requests on
        // stock Komga. Supported activity and tops are independent.
        final summary = object(
          await repository.api.request(
            '/api/v1/stats/reading/summary',
            query: query,
          ),
        );
        final parts = await Future.wait([
          repository.api.request(
            '/api/v1/stats/reading/activity',
            query: {
              ...query,
              'tzOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
            },
          ),
          repository.api.request('/api/v1/stats/reading/tops', query: query),
        ]);
        final activity = object(parts[0]);
        final result = <String, dynamic>{
          ...object(parts[1]),
          ...activity,
          'summary': normalizeReadingSummary(summary),
          'statusDistribution': normalizeStatsItems(
            summary['statusDistribution'],
          ),
          'weekdayDistribution':
              (activity['weekdayDistribution'] as List? ?? [])
                  .map(_statNumber)
                  .toList(),
          'hourlyDistribution': (activity['hourlyDistribution'] as List? ?? [])
              .map(_statNumber)
              .toList(),
          'readingTimeSeries': normalizeStatsItems(
            activity['readingTimeSeries'],
            timeSeries: true,
          ),
          for (final key in [
            'topAuthors',
            'topGenres',
            'topTags',
            'genreDistribution',
            'tagDistribution',
          ])
            key: normalizeStatsItems(object(parts[1])[key]),
          'source': 'server',
          'complete': true,
          'generatedAt':
              summary['generatedAt'] ?? DateTime.now().toIso8601String(),
        };
        store.cache(server, key, result);
        return result;
      } on ApiFailure catch (e) {
        if (e.status != 404) rethrow;
        store.setSetting(capability, DateTime.now().millisecondsSinceEpoch);
      }
    }
    if (repository.offline) {
      final raw = store.cached(server, '${key}Input');
      if (raw != null) {
        final input = object(raw);
        final indexed = <String, Book>{
          for (final dto in input['books'] as List? ?? [])
            text(object(dto)['id']): Book(object(dto)),
        };
        for (final book in store.cachedBooks(server)) {
          if (libraryId == null || book.libraryId == libraryId) {
            indexed[book.id] = book;
          }
        }
        final result = await compute(aggregateReadingStats, {
          ...input,
          'books': indexed.values
              .map(repository.overlay)
              .map((b) => b.json)
              .toList(),
        });
        return {
          ...result,
          'generatedAt': input['synchronizedAt'],
          'offline': true,
        };
      }
      final cached = store.cached(server, key);
      if (cached != null) return {...object(cached), 'offline': true};
      final books = store
          .cachedBooks(server)
          .map(repository.overlay)
          .where((b) => libraryId == null || b.libraryId == libraryId)
          .map((b) => b.json)
          .toList();
      return compute(aggregateReadingStats, {
        'books': books,
        'series': <dynamic>[],
        'total': books.length,
        'complete': false,
      });
    }
    Json? scope = libraryId == null
        ? null
        : {
            'libraryId': {'operator': 'is', 'value': libraryId},
          };
    // Count all books, but retrieve full metadata only for books with progress.
    final count = CatalogPage.parse(
      'books',
      await repository.api.request(
        '/api/v1/books/list',
        method: 'POST',
        body: {'condition': ?scope},
        query: {'size': 1, 'page': 0},
      ),
    ).total;
    final condition = combineConditions([
      scope,
      {
        'readStatus': {'operator': 'isNot', 'value': 'UNREAD'},
      },
    ]);
    final books = <Book>[];
    for (var page = 0; ; page++) {
      if (repository.closed) {
        throw const ApiFailure('The server connection was closed.');
      }
      final chunk = CatalogPage.parse(
        'books',
        await repository.api.request(
          '/api/v1/books/list',
          method: 'POST',
          body: {'condition': condition},
          query: {'page': page, 'size': 100, 'sort': 'id,asc'},
        ),
      );
      repository.store.cacheBooks(server, chunk.items);
      books.addAll(chunk.items.map((b) => repository.overlay(b.book)));
      if (chunk.last || chunk.items.isEmpty) break;
    }
    final series = <Json>[];
    final ids = books
        .where((b) => b.completed)
        .map((b) => b.seriesId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    Future<Json?> fetchSeries(String id) async {
      try {
        final dto = object(
          await repository.api.request(
            '/api/v1/series/${Uri.encodeComponent(id)}',
          ),
        );
        repository.rememberItem(CatalogItem('series', dto));
        return dto;
      } on ApiFailure catch (error) {
        if (error.status == 404) return null;
        rethrow;
      }
    }

    for (var offset = 0; offset < ids.length; offset += 4) {
      if (repository.closed) {
        throw const ApiFailure('The server connection was closed.');
      }
      final rows = await Future.wait(ids.skip(offset).take(4).map(fetchSeries));
      series.addAll(rows.whereType<Json>());
    }
    final input = <String, dynamic>{
      'books': books.map((b) => b.json).toList(),
      'series': series,
      'total': count,
      'complete': true,
      'synchronizedAt': DateTime.now().toIso8601String(),
    };
    final result = await compute(aggregateReadingStats, input);
    if (!repository.closed) {
      store.cache(server, key, result);
      store.cache(server, '${key}Input', input);
    }
    return result;
  }
}

num _statNumber(dynamic value) {
  final result = value is num ? value : num.tryParse('$value');
  return result != null && result.isFinite ? result : 0;
}

Json normalizeReadingSummary(Json data) {
  const aliases = {
    'totalBooks': ['totalBooks', 'totalBookCount', 'booksTotal'],
    'booksStartedReading': [
      'booksStartedReading',
      'booksStarted',
      'startedBooks',
      'booksWithProgress',
    ],
    'booksCompletedReading': [
      'booksCompletedReading',
      'booksCompleted',
      'completedBooks',
    ],
    'totalPagesRead': ['totalPagesRead', 'pagesRead'],
    'averagePagesPerBook': ['averagePagesPerBook', 'avgPagesPerBook'],
    'readingDays': ['readingDays', 'readingStreak', 'activeReadingDays'],
    'estimatedReadingHours': [
      'estimatedReadingHours',
      'estimatedReadingTime',
      'readingHours',
    ],
    'currentStreakDays': ['currentStreakDays'],
    'longestStreakDays': ['longestStreakDays'],
  };
  return {
    for (final entry in aliases.entries)
      if (entry.value.any((key) => data[key] != null))
        entry.key: _statNumber(
          entry.value.map((key) => data[key]).firstWhere((v) => v != null),
        ),
    if (data['lastReadAt'] != null || data['lastReadDate'] != null)
      'lastReadAt': data['lastReadAt'] ?? data['lastReadDate'],
  };
}

List<Json> normalizeStatsItems(dynamic values, {bool timeSeries = false}) => [
  for (final row in (values as List? ?? []).map(object))
    {
      'name': text(
        [
          for (final key in ['name', 'label', 'title', 'key'])
            if (row[key] != null) row[key],
        ].firstOrNull,
        timeSeries
            ? text(
                [
                  for (final key in ['date', 'timestamp', 'time', 'period'])
                    if (row[key] != null) row[key],
                ].firstOrNull,
                '-',
              )
            : '-',
      ),
      'value': _statNumber(
        [
          for (final key
              in (timeSeries
                  ? ['value', 'hours', 'count', 'pagesRead']
                  : ['value', 'count', 'weight', 'hours', 'total']))
            if (row[key] != null) row[key],
        ].firstOrNull,
      ),
      if (timeSeries)
        'date':
            [
              for (final key in ['date', 'timestamp', 'time', 'period'])
                if (row[key] != null) row[key],
            ].firstOrNull ??
            row['name'],
    },
];

Json aggregateReadingStats(Json input) {
  final books = (input['books'] as List).map((v) => Book(object(v))).toList();
  final completed = books.where((b) => b.completed).toList();
  final series = {
    for (final v in input['series'] as List) text(object(v)['id']): object(v),
  };
  final days = <String, int>{},
      authors = <String, int>{},
      genres = <String, int>{},
      tags = <String, int>{};
  final weekdays = List.filled(7, 0), hours = List.filled(24, 0);
  final bySeries = <String, List<Book>>{};
  var pages = 0;
  DateTime? last;
  for (final book in completed) {
    final read = book.pages > 0 ? book.pages : book.page;
    pages += read;
    final date = DateTime.tryParse(
      text(book.progress['readDate'], text(book.progress['lastModified'])),
    )?.toLocal();
    if (date != null) {
      final day =
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      days.update(day, (v) => v + read, ifAbsent: () => read);
      weekdays[date.weekday % 7]++;
      hours[date.hour]++;
      if (last == null || date.isAfter(last)) last = date;
    }
    bySeries.putIfAbsent(book.seriesId, () => []).add(book);
  }
  for (final entry in bySeries.entries) {
    final dto = series[entry.key] ?? <String, dynamic>{};
    final meta = object(dto['metadata']);
    for (final genre
        in (meta['genres'] as List? ?? [])
            .map((v) => '$v')
            .where((v) => v.isNotEmpty)
            .toSet()) {
      genres.update(genre, (v) => v + 1, ifAbsent: () => 1);
    }
    final names = <String>{}, labels = <String>{};
    for (final author
        in object(dto['booksMetadata'])['authors'] as List? ?? []) {
      names.add(text(object(author)['name']));
    }
    labels.addAll((meta['tags'] as List? ?? []).map((v) => '$v'));
    for (final book in entry.value) {
      for (final author in book.metadata['authors'] as List? ?? []) {
        names.add(text(object(author)['name']));
      }
      labels.addAll((book.metadata['tags'] as List? ?? []).map((v) => '$v'));
    }
    for (final name in names.where((v) => v.isNotEmpty)) {
      authors.update(name, (v) => v + 1, ifAbsent: () => 1);
    }
    for (final tag in labels.where((v) => v.isNotEmpty)) {
      tags.update(tag, (v) => v + 1, ifAbsent: () => 1);
    }
  }
  List<Json> ranked(Map<String, int> values) =>
      (values.entries.toList()..sort((a, b) {
            final delta = b.value.compareTo(a.value);
            return delta == 0 ? a.key.compareTo(b.key) : delta;
          }))
          .map((v) => <String, dynamic>{'name': v.key, 'value': v.value})
          .toList();
  final total = integer(input['total']);
  final started = books.where((b) => b.completed || b.page > 0).length;
  return {
    'source': 'local',
    'complete': input['complete'] == true,
    'generatedAt': DateTime.now().toIso8601String(),
    'summary': {
      'totalBooks': total,
      'booksStartedReading': started,
      'booksCompletedReading': completed.length,
      'totalPagesRead': pages,
      'averagePagesPerBook': completed.isEmpty
          ? 0
          : (pages / completed.length).round(),
      'readingDays': days.length,
      'lastReadAt': last?.toIso8601String(),
    },
    'statusDistribution': [
      {'name': 'read', 'value': completed.length},
      {'name': 'inProgress', 'value': started - completed.length},
      {'name': 'unread', 'value': (total - started).clamp(0, total)},
    ],
    'weekdayDistribution': weekdays,
    'hourlyDistribution': hours,
    'readingTimeSeries': [
      for (final day in days.keys.toList()..sort())
        {'name': day, 'date': day, 'value': days[day]},
    ],
    'topAuthors': ranked(authors),
    'topGenres': ranked(genres),
    'topTags': ranked(tags),
    'genreDistribution': ranked(genres),
    'tagDistribution': ranked(tags),
  };
}
