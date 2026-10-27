import 'dart:convert';

import 'api.dart';
import 'models.dart';
import 'repository.dart';

class SmartLists {
  SmartLists(this.repository);
  final Repository repository;
  String get _capability => 'smartListsUnsupported:${repository.profile.id}';
  bool get unsupported {
    final date = repository.store.setting<int>(_capability);
    return date != null &&
        DateTime.now().millisecondsSinceEpoch - date <
            const Duration(days: 1).inMilliseconds;
  }

  Future<List<Json>?> load() async {
    if (repository.offline) {
      throw const ApiFailure(
        'Smart lists are unavailable offline.',
        offline: true,
      );
    }
    if (unsupported) return null;
    try {
      final data = await repository.get(
        '/api/v1/smart-lists',
        query: {'unpaged': true},
      );
      final values = data is List
          ? data
          : object(data)['content'] as List? ?? [];
      return values.map(object).toList();
    } on ApiFailure catch (error) {
      if (error.status != 404) rethrow;
      repository.store.setSetting(
        _capability,
        DateTime.now().millisecondsSinceEpoch,
      );
      return null;
    }
  }

  Future<Json> get(String id) async => object(
    await repository.api.request(
      '/api/v1/smart-lists/${Uri.encodeComponent(id)}',
    ),
  );
  Future<List<Json>> targets() async {
    if (!repository.profile.admin) {
      throw const ApiFailure('Admin access required.', status: 403);
    }
    return (await repository.api.request(
      '/api/v1/smart-lists/share-targets',
    ) as List).map(object).toList();
  }

  Future<String> account() async =>
      repository.profile.userId ??
      text(
        object(
          await repository.get('/api/v2/users/me', cacheFirst: true),
        )['id'],
      );
  Future<void> _writable([Json? item]) async {
    if (repository.offline) {
      throw const ApiFailure(
        'Smart lists are unavailable offline.',
        offline: true,
      );
    }
    if (item != null &&
        !repository.profile.admin &&
        item['ownerId'] != await account()) {
      throw const ApiFailure('Only the owner can edit this list.', status: 403);
    }
  }

  Future<void> save(Json fields, {Json? original}) async {
    await _writable(original);
    final allowed = {
      'name',
      'summary',
      'search',
      if (original == null) 'target',
      if (repository.profile.admin) ...['visibility', 'sharedWithUserIds'],
    };
    if (fields.keys.any((k) => !allowed.contains(k))) {
      throw const ApiFailure('Invalid smart list fields.', status: 403);
    }
    final id = original == null ? null : text(original['id']);
    if (id != null) {
      final latest = await get(id);
      for (final key in fields.keys) {
        if (jsonEncode(original![key]) != jsonEncode(latest[key])) {
          throw const ApiFailure(
            'This list changed on another device. Reload it before saving.',
          );
        }
      }
    }
    await repository.api.request(
      id == null
          ? '/api/v1/smart-lists'
          : '/api/v1/smart-lists/${Uri.encodeComponent(id)}',
      method: id == null ? 'POST' : 'PATCH',
      body: fields,
    );
    repository.refreshContent();
  }

  Future<void> delete(Json item) async {
    await _writable(item);
    await repository.api.request(
      '/api/v1/smart-lists/${Uri.encodeComponent(text(item['id']))}',
      method: 'DELETE',
    );
    repository.refreshContent();
  }
}
