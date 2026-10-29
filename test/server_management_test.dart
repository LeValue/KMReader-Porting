import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/server_management.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late LocalStore store;
  late Directory directory;
  late Repository repository;
  late ServerManagement management;
  late Future<http.Response> Function(http.Request) respond;
  final requests = <http.Request>[];
  setUp(() {
    directory = Directory.systemTemp.createTempSync('server-management-');
    store = LocalStore(sqlite3.openInMemory());
    requests.clear();
    respond = (_) async => http.Response('{}', 200);
    repository = Repository(
      profile: const ServerProfile(
        id: 's',
        name: 'Fixture',
        url: 'https://example.invalid/base',
        email: 'fixture@example.invalid',
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
    );
    management = ServerManagement(repository);
  });
  tearDown(() async {
    await repository.stopDownloadWork();
    store.close();
    directory.deleteSync(recursive: true);
  });
  for (final status in [400, 404]) {
    test(
      'sessions fall back to own user on $status and preserve offline scope',
      () async {
        respond = (request) async {
          if (!request.url.queryParameters.containsKey('username')) {
            return http.Response('', status);
          }
          expect(
            request.url.queryParameters['username'],
            'fixture@example.invalid',
          );
          return http.Response(
            jsonEncode({
              'sessions': [
                {
                  'id': 'earlier',
                  'lastAccessedTime': '2026-01-01T10:00:00+02:00',
                },
                {'id': 'later', 'lastAccessedTime': '2026-01-01T09:00:00Z'},
              ],
            }),
            200,
          );
        };
        final result = await management.sessions();
        expect(result.ownOnly, true);
        expect(result.sessions.first['id'], 'later');
        expect(requests, hasLength(2));
        repository.setOffline(true);
        final offline = await management.sessions();
        expect(offline.ownOnly, true);
        expect(offline.sessions, hasLength(2));
        expect(offline.sessions.first['id'], 'later');
        expect(requests, hasLength(2));
      },
    );
  }
  test(
    'forbidden sessions do not become a fallback or an empty list',
    () async {
      respond = (_) async => http.Response('', 403);
      await expectLater(
        management.sessions(),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
      );
      expect(requests, hasLength(1));
    },
  );
  test(
    'scheduled tasks include every scheduling group and survive offline use',
    () async {
      respond = (_) async => http.Response(
        jsonEncode({
          for (final group in ['cron', 'fixedRate', 'fixedDelay', 'custom'])
            group: [
              {
                'runnable': {'target': group},
                'interval': 1000,
              },
            ],
        }),
        200,
      );
      final tasks = await management.scheduledTasks();
      expect(tasks.map((t) => t['group']).toSet(), {
        'cron',
        'fixedRate',
        'fixedDelay',
        'custom',
      });
      repository.setOffline(true);
      expect(await management.scheduledTasks(), hasLength(4));
      expect(requests, hasLength(1));
    },
  );
  test('task metrics use tagged execution and failure measurements', () async {
    respond = (request) async {
      if (request.url.path.endsWith('/stats/server')) {
        return http.Response('', 404);
      }
      if (request.url.queryParameters['tag'] == null) {
        return http.Response(
          jsonEncode({
            'availableTags': [
              {
                'tag': 'type',
                'values': ['Analyze'],
              },
            ],
          }),
          200,
        );
      }
      expect(request.url.queryParameters['tag'], 'type:Analyze');
      return http.Response(
        jsonEncode({
          'measurements': [
            {
              'statistic': 'COUNT',
              'value': request.url.path.endsWith('failure') ? 2 : 12,
            },
            {'statistic': 'TOTAL_TIME', 'value': 4.5},
            {'statistic': 'MAX', 'value': 1.5},
          ],
        }),
        200,
      );
    };
    final metrics = await management.taskMetrics();
    expect(metrics.single, {
      'type': 'Analyze',
      'count': 12.0,
      'total': 4.5,
      'max': 1.5,
      'failures': 2.0,
    });
    expect(requests, hasLength(4));
    await management.taskMetrics();
    expect(
      requests.where((r) => r.url.path.endsWith('/stats/server')),
      hasLength(1),
    );
  });
  test('only absent metrics soften to unsupported', () async {
    respond = (_) async => http.Response('', 404);
    expect(await management.taskMetrics(), isEmpty);
    respond = (_) async => http.Response('', 403);
    await expectLater(
      management.taskMetrics(),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
    );
  });
  test('server actions preserve base path, encode session IDs and never run offline', () async {
    respond = (_) async => http.Response('', 204);
    await management.revokeSession('id/with spaces');
    await management.cancelTasks();
    await management.shutdown();
    expect(requests.map((r) => r.method).toList(), [
      'DELETE',
      'DELETE',
      'POST',
    ]);
    expect(requests.first.url.pathSegments.last, 'id/with spaces');
    expect(requests[1].url.path, '/base/api/v1/tasks');
    expect(requests[2].url.path, '/base/actuator/shutdown');
    repository.setOffline(true);
    await expectLater(
      management.cancelTasks(),
      throwsA(isA<ApiFailure>().having((e) => e.offline, 'offline', true)),
    );
    expect(requests, hasLength(3));
  });
  test('logs request a bounded tail and are never persisted', () async {
    respond = (request) async {
      expect(request.headers['Range'], 'bytes=-262144');
      return http.Response('Synthetic log\n', 206);
    };
    expect(await management.recentLog(), 'Synthetic log\n');
    expect(store.db.select('SELECT * FROM cache'), isEmpty);
    respond = (_) async => http.Response('x' * (1024 * 1024 + 1), 200);
    await expectLater(management.recentLog(), throwsA(isA<ApiFailure>()));
    expect(store.db.select('SELECT * FROM cache'), isEmpty);
  });
  test(
    'extended task metrics avoid per-type requests and remain usable offline',
    () async {
      respond = (request) async {
        expect(request.url.path, '/base/api/v1/stats/server');
        return http.Response(
          jsonEncode({
            'tasks': {
              'types': [
                {
                  'type': 'Analyze',
                  'executions': 12,
                  'totalTimeMs': 4500,
                  'maxTimeMs': 1500,
                  'failures': 2,
                },
              ],
            },
          }),
          200,
        );
      };
      final metrics = await management.taskMetrics();
      expect(metrics.single['total'], 4.5);
      expect(metrics.single['max'], 1.5);
      expect(metrics.single['count'], 12);
      repository.setOffline(true);
      expect(await management.taskMetrics(), metrics);
      expect(requests, hasLength(1));
    },
  );
  test(
    'extended metric permissions and invalid data never trigger fallback',
    () async {
      respond = (_) async => http.Response('', 403);
      await expectLater(
        management.taskMetrics(),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
      );
      expect(requests, hasLength(1));
      respond = (_) async => http.Response('{}', 200);
      await expectLater(management.taskMetrics(), throwsA(isA<ApiFailure>()));
      expect(requests, hasLength(2));
    },
  );
  test('non-admin accounts are rejected before any transport call', () async {
    final regular = Repository(
      profile: const ServerProfile(
        id: 'regular',
        name: 'Reader',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.apiKey,
      ),
      api: repository.api,
      store: store,
      directory: directory,
    );
    try {
      await expectLater(
        ServerManagement(regular).scheduledTasks(),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
      );
      expect(requests, isEmpty);
    } finally {
      await regular.stopDownloadWork();
    }
  });
  test(
    'complete log export streams to a private file without caching',
    () async {
      final content = 'Synthetic log line\n' * 20000;
      respond = (request) async {
        expect(request.url.path, '/base/actuator/logfile');
        expect(request.headers.containsKey('Range'), false);
        return http.Response(content, 200);
      };
      final target = File('${directory.path}/export/server.log');
      await management.downloadLog(target);
      expect(await target.readAsString(), content);
      expect(await File('${target.path}.part').exists(), false);
      expect(store.db.select('SELECT * FROM cache'), isEmpty);
      repository.setOffline(true);
      await expectLater(
        management.downloadLog(target),
        throwsA(isA<ApiFailure>()),
      );
      expect(requests, hasLength(1));
    },
  );
}
