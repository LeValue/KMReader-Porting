import 'dart:async';
import 'dart:convert';

import 'models.dart';
import 'repository.dart';

class ReadListContinuation {
  ReadListContinuation(this.list, this.book, this.read, this.count);
  final CatalogItem list;
  final Book book;
  final int read, count;
}

/// Uses the same user client-setting keys and payload as upstream KMReader.
/// Pending changes and stop tombstones survive offline use and restarts.
class ReadListReading {
  ReadListReading(this.repository);
  final Repository repository;
  static const prefix = 'kmreader.readlist.';
  bool get enabled =>
      repository.store.setting<bool>('readListContinuationEnabled') ?? false;
  String get _key => 'readListReading';
  Json get states =>
      object(repository.store.cached(repository.profile.id, _key));
  bool _again = false;
  Future<void>? _inFlight;
  String? error;
  void _write(Json value) {
    if (repository.closed) return;
    repository.store.cache(repository.profile.id, _key, value);
    repository.localCatalogChanged();
  }

  static String? settingKey(String id) =>
      RegExp(r'^[a-z0-9]+$', caseSensitive: false).hasMatch(id)
      ? '$prefix${id.toLowerCase()}'
      : null;
  Future<void> setEnabled(bool value) async {
    repository.store.setSetting('readListContinuationEnabled', value);
    repository.localCatalogChanged();
    if (value) await sync();
  }

  CatalogItem? cachedList(String id) {
    final value = repository.store.cached(
      repository.profile.id,
      'detail:readlists:$id',
    );
    return value == null ? null : CatalogItem('readlists', object(value));
  }

  String? owner(String bookId) {
    if (!enabled) return null;
    final ordered =
        states.entries.where((e) => object(e.value)['stopped'] != true).toList()
          ..sort(
            (a, b) => ((object(b.value)['readAt'] as num?) ?? 0).compareTo(
              (object(a.value)['readAt'] as num?) ?? 0,
            ),
          );
    for (final entry in ordered) {
      final list = cachedList(entry.key);
      if (list?.json['ordered'] == true &&
          (list!.json['bookIds'] as List? ?? []).contains(bookId)) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> record(String listId, String bookId) async {
    if (!enabled || repository.closed || settingKey(listId) == null) return;
    final readAt = DateTime.now().microsecondsSinceEpoch / 1000000;
    var list = cachedList(listId);
    if (list == null && !repository.offline) {
      try {
        final data = await repository.get(
          '/api/v1/readlists/${Uri.encodeComponent(listId)}',
          cacheKey: 'detail:readlists:$listId',
          cacheFirst: true,
        );
        list = CatalogItem('readlists', object(data));
      } catch (_) {
        return;
      }
    }
    if (!enabled || repository.closed || list?.json['ordered'] != true) return;
    final values = states, old = object(states[listId]);
    if (((old['readAt'] as num?) ?? 0) > readAt) return;
    values[listId] = {
      'bookId': bookId,
      'readAt': readAt,
      'pending': true,
      'revision': integer(old['revision']) + 1,
    };
    _write(values);
    unawaited(sync());
  }

  Future<void> stop(String listId) async {
    if (!enabled || repository.closed) return;
    final values = states, old = object(values[listId]);
    if (old.isEmpty) return;
    values[listId] = {
      ...old,
      'readAt': DateTime.now().microsecondsSinceEpoch / 1000000,
      'stopped': true,
      'pending': true,
      'revision': integer(old['revision']) + 1,
    };
    _write(values);
    await sync();
  }

  Future<void> sync() {
    if (!enabled || repository.offline || repository.closed) {
      return Future.value();
    }
    final active = _inFlight;
    if (active != null) {
      _again = true;
      return active;
    }
    final future = _synchronize();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<void> _synchronize() async {
    try {
      do {
        _again = false;
        final response = object(
          await repository.api.request('/api/v1/client-settings/user/list'),
        );
        if (repository.closed || !enabled) return;
        final remote = <String, Json>{};
        for (final entry in response.entries.where(
          (e) => e.key.startsWith(prefix),
        )) {
          try {
            final value = object(
              jsonDecode(text(object(entry.value)['value'])),
            );
            final listId = text(value['readListId']),
                bookId = text(value['bookId']),
                readAt = value['readAt'];
            if (settingKey(listId) == entry.key &&
                bookId.isNotEmpty &&
                readAt is num &&
                readAt.isFinite) {
              remote[listId] = {'bookId': bookId, 'readAt': readAt};
            }
          } catch (_) {
            /* Ignore another client's malformed setting only. */
          }
        }
        final values = states;
        for (final entry in values.entries.toList()) {
          if (!remote.containsKey(entry.key) &&
              object(entry.value)['pending'] != true) {
            values.remove(entry.key);
          }
        }
        for (final entry in remote.entries) {
          final local = object(values[entry.key]);
          if (local['pending'] == true && local['stopped'] == true) continue;
          if (local.isEmpty ||
              (entry.value['readAt'] as num) >
                  ((local['readAt'] as num?) ?? 0)) {
            values[entry.key] = {
              ...entry.value,
              'revision': integer(local['revision']) + 1,
            };
          }
        }
        if (jsonEncode(values) != jsonEncode(states)) _write(values);
        final changed = <String, Json>{}, stopped = <String, Json>{};
        for (final entry in values.entries) {
          final value = object(entry.value);
          if (value['pending'] != true || settingKey(entry.key) == null) {
            continue;
          }
          (value['stopped'] == true ? stopped : changed)[entry.key] = value;
        }
        if (changed.isNotEmpty) {
          await repository.api.request(
            '/api/v1/client-settings/user',
            method: 'PATCH',
            body: {
              for (final entry in changed.entries)
                settingKey(entry.key)!: {
                  'value': jsonEncode({
                    'readListId': entry.key,
                    'bookId': entry.value['bookId'],
                    'readAt': entry.value['readAt'],
                  }),
                },
            },
          );
          _ack(changed, remove: false);
        }
        if (stopped.isNotEmpty && !repository.closed && enabled) {
          await repository.api.request(
            '/api/v1/client-settings/user',
            method: 'DELETE',
            body: stopped.keys.map(settingKey).toList(),
          );
          _ack(stopped, remove: true);
        }
        error = null;
      } while (_again && enabled && !repository.closed && !repository.offline);
    } catch (failure) {
      error = failure.toString();
    }
  }

  void _ack(Map<String, Json> sent, {required bool remove}) {
    if (repository.closed) return;
    final values = states;
    for (final entry in sent.entries) {
      final current = object(values[entry.key]);
      if (jsonEncode(current) != jsonEncode(entry.value)) continue;
      if (remove) {
        values.remove(entry.key);
      } else {
        values[entry.key] = {...current, 'pending': false};
      }
    }
    _write(values);
  }

  Future<List<ReadListContinuation>> continuations({
    String? libraryId,
    List<String>? libraryIds,
  }) async {
    if (!enabled || repository.closed) return [];
    final entries =
        states.entries.where((e) => object(e.value)['stopped'] != true).toList()
          ..sort(
            (a, b) => ((object(b.value)['readAt'] as num?) ?? 0).compareTo(
              (object(a.value)['readAt'] as num?) ?? 0,
            ),
          );
    final result = <ReadListContinuation>[];
    for (final entry in entries) {
      var list = cachedList(entry.key);
      try {
        if (!repository.offline) {
          list = CatalogItem(
            'readlists',
            object(
              await repository.get(
                '/api/v1/readlists/${Uri.encodeComponent(entry.key)}',
                cacheKey: 'detail:readlists:${entry.key}',
                cacheFirst: true,
              ),
            ),
          );
        }
        if (list?.json['ordered'] != true || repository.closed) continue;
        final ids = (list!.json['bookIds'] as List? ?? [])
            .whereType<String>()
            .toList();
        // Resolve membership in the read list's order, independent of the
        // dashboard library scope, just as the upstream continuation does.
        final books = <Book>[];
        for (var page = 0; ; page++) {
          final chunk = await repository.catalog(
            'books',
            path: '/api/v1/readlists/${Uri.encodeComponent(entry.key)}/books',
            size: 200,
            page: page,
          );
          books.addAll(chunk.items.map((i) => i.book));
          if (chunk.last || chunk.items.isEmpty || repository.closed) break;
        }
        if (ids.isEmpty) ids.addAll(books.map((b) => b.id));
        final byId = {for (final book in books) book.id: book};
        final last = ids.indexOf(text(object(entry.value)['bookId']));
        int status(String id) {
          final b = byId[id];
          return b?.completed == true
              ? 2
              : (b?.page ?? 0) > 0
              ? 1
              : 0;
        }

        int find(int value, int start) {
          for (var i = start.clamp(0, ids.length); i < ids.length; i++) {
            if (status(ids[i]) == value) return i;
          }
          return ids.indexWhere((id) => status(id) == value);
        }

        var index = find(1, last);
        if (index < 0 && ids.any((id) => status(id) == 2)) {
          index = find(0, last + 1);
        }
        if (index < 0) continue;
        final book = byId[ids[index]];
        if (book == null ||
            libraryId != null && book.libraryId != libraryId ||
            libraryIds != null &&
                libraryIds.isNotEmpty &&
                !libraryIds.contains(book.libraryId)) {
          continue;
        }
        result.add(
          ReadListContinuation(
            list,
            book,
            books.where((b) => b.completed).length,
            ids.length,
          ),
        );
      } catch (_) {
        /* One inaccessible list must not hide other continuations. */
      }
    }
    return result;
  }
}
