import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'repository.dart';

typedef KomfProviderLink = ({String provider, String id, Uri url});

List<KomfProviderLink> komfProviderLinks(Iterable<dynamic> links) {
  final result = <KomfProviderLink>[];
  final seen = <String>{};
  for (final raw in links) {
    final uri = Uri.tryParse(text(object(raw)['url']));
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      continue;
    }
    final host = uri.host.toLowerCase();
    bool domain(String value) => host == value || host.endsWith('.$value');
    final path = uri.pathSegments;
    String? provider, id;
    if ((domain('bgm.tv') || domain('bangumi.tv')) &&
        path.length >= 2 &&
        path[0] == 'subject') {
      provider = 'BANGUMI';
      id = path[1];
    } else if ((domain('e-hentai.org') || domain('exhentai.org')) &&
        path.length >= 3 &&
        path[0] == 'g') {
      provider = 'EHENTAI';
      id = '${path[1]};${path[2]}';
    } else if ((domain('anilist.co') || domain('myanimelist.net')) &&
        path.length >= 2 &&
        ['anime', 'manga'].contains(path[0]) &&
        RegExp(r'^\d+$').hasMatch(path[1])) {
      provider = domain('anilist.co') ? 'ANILIST' : 'MAL';
      id = path[1];
    } else if (domain('mangadex.org') &&
        path.length >= 2 &&
        path[0] == 'title') {
      provider = 'MANGADEX';
      id = path[1];
    } else if (domain('mangaupdates.com')) {
      if (path.length >= 2 && path[0] == 'series') {
        id = path[1];
      } else if (path.length == 1 &&
          path[0] == 'series.html' &&
          RegExp(r'^\d+$').hasMatch(uri.queryParameters['id'] ?? '')) {
        id = uri.queryParameters['id'];
      }
      provider = 'MANGA_UPDATES';
    }
    if (provider != null &&
        id != null &&
        id.isNotEmpty &&
        seen.add('$provider:$id')) {
      result.add((provider: provider, id: id, url: uri));
    }
  }
  return result;
}

/// The optional kmrs Komf proxy. All requests remain scoped to this repository;
/// provider artwork and websites never receive its authentication headers.
class Komf extends ChangeNotifier {
  Komf(
    this.repository, {
    this.pollInterval = const Duration(seconds: 2),
    this.maxPollAttempts = 300,
  });
  final Repository repository;
  final Duration pollInterval;
  final int maxPollAttempts;
  Json? integration;
  final Map<String, Json> _jobs = {};
  Map<String, Json> get jobs => Map.unmodifiable({
    for (final entry in _jobs.entries)
      entry.key: Map<String, dynamic>.unmodifiable(entry.value),
  });
  Future<Json?>? _integrationRequest;
  Timer? _timer;
  bool _closed = false, _polling = false;
  bool get _active => !_closed && !repository.closed;
  bool get connected => integration?['state'] == 'connected';
  String get _capabilityKey => 'komfUnsupported:${repository.profile.id}';

  void _require() {
    if (!repository.profile.admin) {
      throw const ApiFailure('Admin access required.', status: 403);
    }
    if (!_active) throw const ApiFailure('The server connection was closed.');
    if (repository.offline) {
      throw const ApiFailure('Reconnect to manage the server.', offline: true);
    }
  }

  Future<Json?> checkIntegration({bool force = false}) {
    if (!repository.profile.admin || !_active || repository.offline) {
      return Future.value(null);
    }
    if (!force && connected) return Future.value(integration);
    final pending = _integrationRequest;
    if (pending != null) return pending;
    final unsupported = repository.store.setting<int>(_capabilityKey);
    final now = repository.cacheClock().millisecondsSinceEpoch;
    if (!force &&
        unsupported != null &&
        now >= unsupported &&
        now - unsupported < const Duration(days: 1).inMilliseconds) {
      return Future.value(null);
    }
    return _integrationRequest = _check().whenComplete(
      () => _integrationRequest = null,
    );
  }

  Future<Json?> _check() async {
    try {
      final response = object(
        await repository.api.request('/api/v1/komf/integration'),
      );
      if (!_active || repository.offline) return null;
      integration = response;
      repository.store.setSetting(_capabilityKey, null);
      notifyListeners();
      return integration;
    } on ApiFailure catch (error) {
      if (_active) {
        integration = null;
        if (error.status == 404) {
          repository.store.setSetting(
            _capabilityKey,
            repository.cacheClock().millisecondsSinceEpoch,
          );
          notifyListeners();
          return null;
        }
      }
      rethrow;
    }
  }

  Future<T> _action<T>(Future<T> Function() perform) async {
    _require();
    try {
      return await perform();
    } on ApiFailure catch (error) {
      if (error.status == 409 && _active) {
        integration = null;
        repository.store.setSetting(_capabilityKey, null);
        notifyListeners();
        unawaited(checkIntegration(force: true).catchError((Object _) => null));
      }
      rethrow;
    }
  }

  Future<List<Json>> search({
    required String name,
    required String libraryId,
    required String seriesId,
  }) => _action(() async {
    if (name.trim().isEmpty) return [];
    final result = await repository.api.request(
      '/api/v1/komf/search',
      query: {
        'name': name.trim(),
        'libraryId': libraryId,
        'seriesId': seriesId,
      },
    );
    if (result is! List) {
      throw const ApiFailure('The server returned an unexpected response.');
    }
    return result.map(object).toList();
  });

  Future<String> identify({
    required String libraryId,
    required String seriesId,
    required String title,
    required String provider,
    required String providerSeriesId,
  }) => _action(() async {
    final response = object(
      await repository.api.request(
        '/api/v1/komf/identify',
        method: 'POST',
        body: {
          'libraryId': libraryId,
          'seriesId': seriesId,
          'provider': provider,
          'providerSeriesId': providerSeriesId,
        },
      ),
    );
    return _track(response, seriesId, title);
  });

  Future<String> match({
    required String libraryId,
    required String seriesId,
    required String title,
  }) => _action(() async {
    final response = object(
      await repository.api.request(
        '/api/v1/komf/match/library/${Uri.encodeComponent(libraryId)}/series/${Uri.encodeComponent(seriesId)}',
        method: 'POST',
      ),
    );
    return _track(response, seriesId, title);
  });

  Future<void> reset({
    required String libraryId,
    required String seriesId,
  }) => _action(() async {
    await repository.api.request(
      '/api/v1/komf/reset/library/${Uri.encodeComponent(libraryId)}/series/${Uri.encodeComponent(seriesId)}',
      method: 'POST',
    );
    await _refreshSeries(seriesId);
  });

  String _track(Json response, String seriesId, String title) {
    final id = text(response['id']);
    if (id.isEmpty) {
      throw const ApiFailure('The server returned an unexpected response.');
    }
    if (_active) {
      _jobs.putIfAbsent(
        id,
        () => {
          'id': id,
          'seriesId': seriesId,
          'title': title,
          'status': 'RUNNING',
          'attempts': 0,
          'errors': 0,
        },
      );
      while (_jobs.length > 50) {
        final old = _jobs.keys
            .where((key) => _jobs[key]!['status'] != 'RUNNING')
            .firstOrNull;
        if (old == null) break;
        _jobs.remove(old);
      }
      _timer ??= Timer.periodic(pollInterval, (_) => unawaited(pollJobs()));
      notifyListeners();
    }
    return id;
  }

  Future<void> _refreshSeries(String seriesId) async {
    if (!_active || repository.offline) return;
    try {
      final data = object(
        await repository.api.request(
          '/api/v1/series/${Uri.encodeComponent(seriesId)}',
        ),
      );
      if (!_active || repository.offline) return;
      if (data['id'] != seriesId) {
        throw const ApiFailure('The server returned an unexpected response.');
      }
      repository.rememberItem(CatalogItem('series', data));
      repository.store.cacheItems(repository.profile.id, [
        CatalogItem('series', data),
      ]);
    } catch (_) {
      // SSE may be disabled. Still invalidate catalog snapshots if detail sync fails.
    }
    if (_active) repository.refreshContent();
  }

  /// One non-overlapping polling pass, also used by the visible refresh action.
  Future<void> pollJobs() async {
    if (!_active || repository.offline || _polling) return;
    _polling = true;
    try {
      final running = _jobs.entries
          .where((e) => e.value['status'] == 'RUNNING')
          .toList();
      for (final entry in running) {
        if (!_active || repository.offline) return;
        final job = {...entry.value};
        job['attempts'] = integer(job['attempts']) + 1;
        try {
          final response = object(
            await repository.api.request(
              '/api/v1/komf/jobs/${Uri.encodeComponent(entry.key)}',
            ),
          );
          if (!_active || repository.offline) return;
          if (response['seriesId'] != job['seriesId'] ||
              response['id'] != entry.key ||
              ![
                'RUNNING',
                'COMPLETED',
                'FAILED',
              ].contains(response['status'])) {
            throw const ApiFailure(
              'The server returned an unexpected response.',
            );
          }
          job.addAll({
            ...response,
            'message': response['message'],
            'errors': 0,
          });
        } catch (error) {
          if (!_active || repository.offline) return;
          job['errors'] = integer(job['errors']) + 1;
          job['message'] = error.toString();
          if (error is ApiFailure && error.status == 404) {
            job['status'] = 'FAILED';
          } else if (integer(job['errors']) >= 5) {
            job['status'] = 'TRACKING_STOPPED';
          }
        }
        if (job['status'] == 'RUNNING' &&
            integer(job['attempts']) >= maxPollAttempts) {
          job['status'] = 'TRACKING_STOPPED';
        }
        _jobs[entry.key] = job;
        if (['COMPLETED', 'TRACKING_STOPPED'].contains(job['status'])) {
          await _refreshSeries(text(job['seriesId']));
        }
        if (!_active) return;
        notifyListeners();
      }
      if (!_jobs.values.any((job) => job['status'] == 'RUNNING')) {
        _timer?.cancel();
        _timer = null;
      }
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}
