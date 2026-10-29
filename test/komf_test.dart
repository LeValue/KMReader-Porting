import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/komf.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late LocalStore store;
  late Directory directory;
  late Repository repository;
  late Komf komf;
  late DateTime now;
  late Future<http.Response> Function(http.Request) respond;
  final requests = <http.Request>[];
  setUp(() {
    store = LocalStore(sqlite3.openInMemory());
    directory = Directory.systemTemp.createTempSync('komf-test-');
    now = DateTime.utc(2026, 1, 1);
    requests.clear();
    respond = (request) async {
      if (request.url.path.endsWith('/integration')) {
        return http.Response('{"state":"connected"}', 200);
      }
      if (request.url.path.contains('/jobs/')) {
        return http.Response(
          '{"id":"job","seriesId":"series","status":"RUNNING"}',
          200,
        );
      }
      if (request.url.path.endsWith('/series/series') &&
          request.method == 'GET') {
        return http.Response(
          '{"id":"series","metadata":{"title":"Updated"}}',
          200,
        );
      }
      return http.Response('{"id":"job"}', 200);
    };
    repository = Repository(
      profile: const ServerProfile(
        id: 's',
        name: 'Fixture',
        url: 'https://example.invalid/base',
        email: '',
        authentication: Authentication.apiKey,
        admin: true,
      ),
      api: KomgaApi(
        Uri.parse('https://example.invalid/base'),
        authentication: Authentication.apiKey,
        credential: 'fixture',
        client: MockClient((request) async {
          requests.add(request);
          return respond(request);
        }),
      ),
      store: store,
      directory: directory,
      cacheClock: () => now,
    );
    komf = Komf(repository, pollInterval: const Duration(days: 1));
  });
  tearDown(() async {
    komf.dispose();
    await repository.stopDownloadWork();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('provider links preserve identifiers and order, deduplicate and match real hosts', () {
    final links = komfProviderLinks([
      for (final url in [
        'https://bgm.tv/subject/123',
        'https://bangumi.tv/subject/123',
        'https://e-hentai.org/g/12/Token/',
        'https://anilist.co/manga/34/title',
        'https://myanimelist.net/manga/56',
        'https://mangadex.org/title/ID',
        'https://www.mangaupdates.com/series/abc/title',
        'https://mangaupdates.com/series.html?id=78',
        'https://mangadex.org.evil.invalid/title/fake',
        'https://evil.invalid/?url=https://anilist.co/manga/99',
        'file:///anilist.co/manga/99',
      ])
        {'url': url},
    ]);
    expect(links.map((e) => '${e.provider}:${e.id}').toList(), [
      'BANGUMI:123',
      'EHENTAI:12;Token',
      'ANILIST:34',
      'MAL:56',
      'MANGADEX:ID',
      'MANGA_UPDATES:abc',
      'MANGA_UPDATES:78',
    ]);
  });
  test('connected integration coalesces concurrent checks and latches only connected state', () async {
    final gate = Completer<http.Response>();
    respond = (_) => gate.future;
    final first = komf.checkIntegration(), second = komf.checkIntegration();
    gate.complete(http.Response('{"state":"connected"}', 200));
    expect(await first, await second);
    expect(komf.connected, true);
    await komf.checkIntegration();
    expect(requests, hasLength(1));
    respond = (_) async => http.Response('{"state":"pending"}', 200);
    await komf.checkIntegration(force: true);
    expect(komf.connected, false);
    await komf.checkIntegration();
    expect(requests, hasLength(3));
  });
  test('only 404 disables integration for 24 hours, with forced and clock-change retry', () async {
    respond = (_) async => http.Response('', 404);
    expect(await komf.checkIntegration(), isNull);
    await komf.checkIntegration();
    expect(requests, hasLength(1));
    now = now.add(const Duration(days: 1));
    await komf.checkIntegration();
    expect(requests, hasLength(2));
    await komf.checkIntegration(force: true);
    expect(requests, hasLength(3));
    now = now.subtract(const Duration(days: 2));
    respond = (_) async => http.Response('', 403);
    await expectLater(
      komf.checkIntegration(),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
    );
    await expectLater(komf.checkIntegration(), throwsA(isA<ApiFailure>()));
    expect(requests, hasLength(5));
  });
  test('search and identify preserve scope and provider references without retrying writes', () async {
    respond = (request) async {
      if (request.url.path.endsWith('/search')) {
        expect(request.url.queryParameters, {
          'name': 'Café',
          'libraryId': 'lib/1',
          'seriesId': 'series/1',
        });
        return http.Response(
          '[{"title":"Café","provider":"MANGADEX","resultId":"ID"}]',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      expect(request.method, 'POST');
      expect(jsonDecode(request.body), {
        'libraryId': 'lib/1',
        'seriesId': 'series/1',
        'provider': 'MANGADEX',
        'providerSeriesId': 'ID',
      });
      return http.Response('', 503);
    };
    expect(
      (await komf.search(
        name: ' Café ',
        libraryId: 'lib/1',
        seriesId: 'series/1',
      )).single['resultId'],
      'ID',
    );
    await expectLater(
      komf.identify(
        libraryId: 'lib/1',
        seriesId: 'series/1',
        title: 'Title',
        provider: 'MANGADEX',
        providerSeriesId: 'ID',
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests, hasLength(2));
    expect(komf.jobs, isEmpty);
  });
  test(
    'encoded series actions and reset refresh the correct catalog detail',
    () async {
      await komf.match(
        libraryId: 'lib/1',
        seriesId: 'series/1',
        title: 'Title',
      );
      expect(requests.first.url.pathSegments.sublist(5), [
        'library',
        'lib/1',
        'series',
        'series/1',
      ]);
      await komf.reset(libraryId: 'lib', seriesId: 'series');
      expect(requests[1].method, 'POST');
      expect(object(store.cached('s', 'detail:series:series'))['metadata'], {
        'title': 'Updated',
      });
      expect(repository.contentRevision, 1);
    },
  );
  test('jobs finish and refresh metadata without requiring SSE', () async {
    await komf.match(libraryId: 'lib', seriesId: 'series', title: 'Title');
    final old = komf.jobs;
    await komf.pollJobs();
    expect(komf.jobs['job']!['status'], 'RUNNING');
    final fallback = respond;
    respond = (request) async => request.url.path.contains('/jobs/')
        ? http.Response(
            '{"id":"job","seriesId":"series","status":"COMPLETED"}',
            200,
          )
        : fallback(request);
    await komf.pollJobs();
    expect(komf.jobs['job']!['status'], 'COMPLETED');
    expect(old['job']!['status'], 'RUNNING');
    expect(repository.contentRevision, 1);
    expect(object(store.cached('s', 'detail:series:series'))['metadata'], {
      'title': 'Updated',
    });
    final count = requests.length;
    await komf.pollJobs();
    expect(requests, hasLength(count));
  });
  test(
    'polling never overlaps and ignores a completion after repository close',
    () async {
      await komf.match(libraryId: 'lib', seriesId: 'series', title: 'Title');
      final gate = Completer<http.Response>();
      respond = (_) => gate.future;
      final first = komf.pollJobs();
      await Future<void>.delayed(Duration.zero);
      await komf.pollJobs();
      expect(
        requests.where((r) => r.url.path.contains('/jobs/')),
        hasLength(1),
      );
      repository.dispose();
      gate.complete(
        http.Response(
          '{"id":"job","seriesId":"series","status":"COMPLETED"}',
          200,
        ),
      );
      await first;
      expect(store.cached('s', 'detail:series:series'), isNull);
      expect(komf.jobs['job']!['status'], 'RUNNING');
    },
  );
  test('offline polls pause and a missing job reports failure instead of completion', () async {
    await komf.match(libraryId: 'lib', seriesId: 'series', title: 'Title');
    repository.setOffline(true);
    await komf.pollJobs();
    expect(requests, hasLength(1));
    await expectLater(
      komf.reset(libraryId: 'lib', seriesId: 'series'),
      throwsA(isA<ApiFailure>().having((e) => e.offline, 'offline', true)),
    );
    repository.setOffline(false);
    respond = (_) async => http.Response('', 404);
    await komf.pollJobs();
    expect(komf.jobs['job']!['status'], 'FAILED');
  });
  test(
    'polling timeout reports tracking stopped and refreshes partial metadata',
    () async {
      komf.dispose();
      komf = Komf(
        repository,
        pollInterval: const Duration(days: 1),
        maxPollAttempts: 2,
      );
      await komf.match(libraryId: 'lib', seriesId: 'series', title: 'Title');
      await komf.pollJobs();
      await komf.pollJobs();
      expect(komf.jobs['job']!['status'], 'TRACKING_STOPPED');
      expect(repository.contentRevision, 1);
    },
  );
  test('repeated polling errors stop tracking without claiming the server job failed', () async {
    await komf.match(libraryId: 'lib', seriesId: 'series', title: 'Title');
    final fallback = respond;
    respond = (request) async => request.url.path.contains('/jobs/')
        ? http.Response('', 503)
        : fallback(request);
    for (var attempt = 0; attempt < 5; attempt++) {
      await komf.pollJobs();
    }
    expect(komf.jobs['job']!['status'], 'TRACKING_STOPPED');
    expect(repository.contentRevision, 1);
  });
  test(
    'regular accounts do not probe Komf or submit administrative actions',
    () async {
      final reader = Repository(
        profile: const ServerProfile(
          id: 'reader',
          name: 'Reader',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        ),
        api: repository.api,
        store: store,
        directory: directory,
      );
      final client = reader.komf;
      try {
        expect(await client.checkIntegration(), isNull);
        await expectLater(
          client.match(libraryId: 'lib', seriesId: 'series', title: 'Title'),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
        );
        expect(requests, isEmpty);
      } finally {
        await reader.stopDownloadWork();
      }
    },
  );
  test('integration conflict invalidates connected state and rechecks the same server', () async {
    await komf.checkIntegration();
    respond = (request) async => http.Response(
      '',
      request.url.path.endsWith('/integration') ? 404 : 409,
    );
    await expectLater(
      komf.match(libraryId: 'lib', seriesId: 'series', title: 'Title'),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 409)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(komf.connected, false);
    expect(
      requests.where((r) => r.url.path.endsWith('/integration')),
      hasLength(2),
    );
    expect(komf.jobs, isEmpty);
  });
}
