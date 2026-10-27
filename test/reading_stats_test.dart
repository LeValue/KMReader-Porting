import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/reading_stats.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/settings/library_editor.dart';

void main() {
  test('extended statistics accept upstream aliases and string numbers', () {
    expect(
      normalizeReadingSummary({
        'booksTotal': '12',
        'pagesRead': '99',
        'currentStreakDays': '3',
      }),
      {'totalBooks': 12, 'totalPagesRead': 99, 'currentStreakDays': 3},
    );
    expect(
      normalizeStatsItems([
        {'label': 'Writer', 'weight': '2.5'},
      ]),
      [
        {'name': 'Writer', 'value': 2.5},
      ],
    );
    expect(
      normalizeStatsItems([
        {'timestamp': '2026-10-27', 'pagesRead': '6'},
      ], timeSeries: true),
      [
        {'name': '2026-10-27', 'date': '2026-10-27', 'value': 6},
      ],
    );
  });
  test(
    'local statistics match upstream completed-book and per-series dimensions',
    () {
      final result = aggregateReadingStats({
        'total': 4,
        'complete': true,
        'books': [
          for (var i = 0; i < 2; i++)
            {
              'id': '$i',
              'seriesId': 'series',
              'media': {'pagesCount': 10},
              'metadata': {
                'authors': [
                  {'name': 'Author'},
                ],
                'tags': ['tag'],
              },
              'readProgress': {
                'completed': true,
                'page': 10,
                'readDate': '2026-10-25T10:00:00Z',
              },
            },
          {
            'id': 'active',
            'media': {'pagesCount': 5},
            'readProgress': {'completed': false, 'page': 2},
          },
        ],
        'series': [
          {
            'id': 'series',
            'metadata': {
              'genres': ['Fiction'],
              'tags': ['tag'],
            },
          },
        ],
      });
      expect(object(result['summary']), containsPair('totalPagesRead', 20));
      expect(object(result['summary']), containsPair('booksStartedReading', 3));
      expect(object(result['summary']), containsPair('readingDays', 1));
      expect(result['topAuthors'], [
        {'name': 'Author', 'value': 1},
      ]);
      expect(result['topGenres'], [
        {'name': 'Fiction', 'value': 1},
      ]);
      expect(result['topTags'], [
        {'name': 'tag', 'value': 1},
      ]);
      expect(
        (result['readingTimeSeries'] as List).single,
        containsPair('value', 20),
      );
      expect(result['weekdayDistribution'], [2, 0, 0, 0, 0, 0, 0]);
    },
  );
  test(
    'library creation includes every required flag; editing sends only changes',
    () {
      final values = defaultLibrary()
        ..addAll({'name': 'Test', 'root': '/books'});
      final creation = libraryPatch(values, null);
      expect(creation.keys.length, defaultLibrary().length);
      expect(creation['scanInterval'], 'EVERY_6H');
      expect(creation['scanDirectoryExclusions'], [
        '#recycle',
        '@eaDir',
        '@Recycle',
      ]);
      expect(libraryPatch({...values, 'hashPages': true}, values), {
        'hashPages': true,
      });
      expect(
        () => libraryPatch({...values, 'root': ' '}, values),
        throwsFormatException,
      );
    },
  );
  test('only 404 enables local fallback; account errors never become empty statistics', () async {
    final store = LocalStore(sqlite3.openInMemory());
    final directory = Directory.systemTemp.createTempSync('reading-stats-');
    var status = 403, probes = 0;
    final repository = Repository(
      profile: const ServerProfile(
        id: 's',
        name: 'Test',
        url: 'https://example.invalid',
        email: 'test@example.invalid',
        authentication: Authentication.apiKey,
      ),
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.apiKey,
        credential: 'synthetic',
        client: MockClient((request) async {
          if (request.url.path.startsWith('/api/v1/stats/')) {
            probes++;
            return http.Response('', status);
          }
          return http.Response(
            jsonEncode({
              'content': <dynamic>[],
              'last': true,
              'totalElements': 0,
            }),
            200,
          );
        }),
      ),
    );
    try {
      await expectLater(
        ReadingStats(repository).load(),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
      );
      expect(store.setting<int>('readingStatsCapability:s'), isNull);
      status = 404;
      expect((await ReadingStats(repository).load())['source'], 'local');
      expect((await ReadingStats(repository).load())['source'], 'local');
      expect(probes, 2);
      repository.setOffline(true);
      final cached = await ReadingStats(repository).load();
      expect(cached['offline'], isTrue);
      expect(cached['complete'], isTrue);
      expect(probes, 2);
    } finally {
      repository.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
}
