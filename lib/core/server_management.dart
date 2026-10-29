import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'api.dart';
import 'models.dart';
import 'repository.dart';

class ServerManagement {
  ServerManagement(this.repository);
  final Repository repository;
  void _require({bool online = false}) {
    if (!repository.profile.admin) {
      throw const ApiFailure('Admin access required.', status: 403);
    }
    if (online && repository.offline) {
      throw const ApiFailure('Reconnect to manage the server.', offline: true);
    }
    if (repository.closed) {
      throw const ApiFailure('The server connection was closed.');
    }
  }

  Future<Json?> _optionalMetric(String name, {String? type}) async {
    try {
      return object(
        await repository.get(
          '/actuator/metrics/${Uri.encodeComponent(name)}',
          query: type == null ? null : {'tag': 'type:$type'},
        ),
      );
    } on ApiFailure catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  Future<List<Json>> taskMetrics() async {
    _require();
    final capabilityKey = 'serverTaskStatsUnsupported:${repository.profile.id}';
    final unsupported = repository.store.setting<int>(capabilityKey);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (unsupported == null ||
        now - unsupported >= const Duration(days: 1).inMilliseconds ||
        now < unsupported) {
      try {
        final stats = object(await repository.get('/api/v1/stats/server'));
        final types = object(stats['tasks'])['types'];
        if (types is! List) {
          throw const ApiFailure('The server returned an unexpected response.');
        }
        double number(Json value, String key) {
          final raw = value[key];
          return raw is num && raw.isFinite ? raw.toDouble() : 0;
        }

        final result = types
            .map(object)
            .map(
              (task) => <String, dynamic>{
                'type': text(task['type']),
                'count': number(task, 'executions'),
                'total': number(task, 'totalTimeMs') / 1000,
                'max': number(task, 'maxTimeMs') / 1000,
                'failures': number(task, 'failures'),
              },
            )
            .toList();
        result.sort(
          (a, b) => (b['count'] as double).compareTo(a['count'] as double),
        );
        return result;
      } on ApiFailure catch (error) {
        if (repository.offline && error.offline) {
          // Older offline snapshots may contain only Actuator measurements.
        } else if (error.status == 404) {
          repository.store.setSetting(capabilityKey, now);
        } else {
          rethrow;
        }
      }
    }
    final metric = await _optionalMetric('komga.tasks.execution');
    if (metric == null) return [];
    final tags = (metric['availableTags'] as List? ?? []).map(object);
    final types =
        (tags.where((tag) => tag['tag'] == 'type').firstOrNull?['values']
                    as List? ??
                [])
            .whereType<String>()
            .take(100)
            .toList();
    double value(Json? metric, String statistic) {
      final measurements = (metric?['measurements'] as List? ?? []).map(object);
      final number = measurements
          .where((m) => m['statistic'] == statistic)
          .firstOrNull?['value'];
      return number is num && number.isFinite ? number.toDouble() : 0;
    }

    final result = <Json>[];
    for (var offset = 0; offset < types.length; offset += 4) {
      result.addAll(
        await Future.wait(
          types.skip(offset).take(4).map((type) async {
            final metrics = await Future.wait([
              _optionalMetric('komga.tasks.execution', type: type),
              _optionalMetric('komga.tasks.failure', type: type),
            ]);
            return <String, dynamic>{
              'type': type,
              'count': value(metrics[0], 'COUNT'),
              'total': value(metrics[0], 'TOTAL_TIME'),
              'max': value(metrics[0], 'MAX'),
              'failures': value(metrics[1], 'COUNT'),
            };
          }),
        ),
      );
    }
    result.sort(
      (a, b) => (b['count'] as double).compareTo(a['count'] as double),
    );
    return result;
  }

  Future<List<Json>> scheduledTasks() async {
    _require();
    final data = object(await repository.get('/actuator/scheduledtasks'));
    return [
      for (final group in ['cron', 'fixedRate', 'fixedDelay', 'custom'])
        for (final item in data[group] as List? ?? [])
          {...object(item), 'group': group},
    ];
  }

  List<Json> _orderedSessions(Json data) {
    final sessions = (data['sessions'] as List? ?? []).map(object).toList();
    sessions.sort(
      (a, b) =>
          (DateTime.tryParse(text(b['lastAccessedTime']))
                      ?.millisecondsSinceEpoch ??
                  0)
              .compareTo(
                DateTime.tryParse(text(a['lastAccessedTime']))
                        ?.millisecondsSinceEpoch ??
                    0,
              ),
    );
    return sessions;
  }

  Future<({List<Json> sessions, bool ownOnly})> sessions() async {
    _require();
    Json data;
    var ownOnly = false;
    final scopeKey = 'sessionScopeOwn:${repository.profile.id}';
    if (repository.offline &&
        repository.store.setting<bool>(scopeKey) == true) {
      data = object(
        await repository.get(
          '/actuator/sessions',
          query: {'username': repository.profile.email},
        ),
      );
      return (sessions: _orderedSessions(data), ownOnly: true);
    }
    try {
      data = object(await repository.get('/actuator/sessions'));
    } on ApiFailure catch (error) {
      if (![400, 404].contains(error.status) ||
          repository.profile.email.isEmpty) {
        rethrow;
      }
      data = object(
        await repository.get(
          '/actuator/sessions',
          query: {'username': repository.profile.email},
        ),
      );
      ownOnly = true;
    }
    repository.store.setSetting(scopeKey, ownOnly);
    return (sessions: _orderedSessions(data), ownOnly: ownOnly);
  }

  Future<void> revokeSession(String id) async {
    _require(online: true);
    await repository.api.request(
      '/actuator/sessions/${Uri.encodeComponent(id)}',
      method: 'DELETE',
    );
  }

  Future<void> cancelTasks() async {
    _require(online: true);
    await repository.api.request('/api/v1/tasks', method: 'DELETE');
  }

  Future<void> shutdown() async {
    _require(online: true);
    await repository.api.request('/actuator/shutdown', method: 'POST');
  }

  Future<String> recentLog() async {
    _require(online: true);
    final response = await repository.api.send(
      '/actuator/logfile',
      extra: {'Accept': 'text/plain', 'Range': 'bytes=-262144'},
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 45),
    )) {
      if (bytes.length + chunk.length > 1024 * 1024) {
        throw const ApiFailure(
          'The server did not limit the log response to the requested size.',
        );
      }
      bytes.add(chunk);
    }
    // This can contain private operational data; it is never persisted to cache.
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<void> downloadLog(File target, {bool Function()? cancelled}) async {
    _require(online: true);
    await repository.api.download(
      '/actuator/logfile',
      target,
      cancelled: cancelled,
    );
  }
}
