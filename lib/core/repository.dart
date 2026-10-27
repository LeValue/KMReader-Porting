import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'models.dart';
import 'store.dart';

class Repository extends ChangeNotifier {
  Repository({
    required this.profile,
    required this.api,
    required this.store,
    required this.directory,
  });
  final ServerProfile profile;
  final KomgaApi api;
  final LocalStore store;
  final Directory directory;
  bool offline = false;
  bool _syncing = false;
  bool _disposed = false;
  StreamSubscription<String>? _events;
  Timer? _refreshTimer, _reconnect;
  int revision = 0;
  int contentRevision = 0;
  int progressRevision = 0;
  String? syncFailure;
  final Map<String, Json> conflicts = {};
  Timer? _eventReconnect;
  final Map<String, Future<Uint8List>> _images = {};
  final Map<String, double> downloading = {};
  final Set<String> _cancelled = {};
  int get pendingCount => store.pending(profile.id).length;
  bool get closed => _disposed;
  String fileKey(String key) => sha256.convert(utf8.encode(key)).toString();
  File cachedFile(String key) =>
      File(p.join(directory.path, profile.id, 'cache', fileKey(key)));
  Directory bookDirectory(String id) =>
      Directory(p.join(directory.path, profile.id, 'books', fileKey(id)));
  File pageFile(String id, int page) =>
      File(p.join(bookDirectory(id).path, 'page-$page'));
  File bookFile(Book book) => File(
    p.join(
      bookDirectory(book.id).path,
      'source.${book.format == 'comic' ? 'archive' : book.format}',
    ),
  );
  void changed() {
    if (!_disposed) {
      revision++;
      notifyListeners();
    }
  }

  void refreshContent() {
    contentRevision++;
    changed();
  }

  Future<dynamic> get(
    String path, {
    String method = 'GET',
    dynamic body,
    Map<String, dynamic>? query,
  }) async {
    final key = jsonEncode([path, method, body, query]);
    if (!offline) {
      try {
        final value = await api.request(
          path,
          method: method,
          body: body,
          query: query,
        );
        store.cache(profile.id, key, value);
        return value;
      } on ApiFailure catch (e) {
        if (!e.offline && (e.status == null || e.status! < 500)) rethrow;
        final cached = store.cached(profile.id, key);
        if (cached != null) return cached;
        rethrow;
      }
    }
    final cached = store.cached(profile.id, key);
    if (cached == null) {
      throw const ApiFailure(
        'This content has not been saved for offline use.',
        offline: true,
      );
    }
    return cached;
  }

  Book overlay(Book book) {
    final local = store.progress(profile.id, book.id);
    if (local == null) return book;
    if (local['kind'] == 'epub') return book;
    if (local['reset'] == true) return book.withProgress(null);
    final remoteDate = DateTime.tryParse(text(book.progress['lastModified']));
    final localDate = DateTime.tryParse(text(local['lastModified']));
    if (remoteDate != null &&
        localDate != null &&
        remoteDate.isAfter(localDate) &&
        !store.pending(profile.id).any((r) => r['book'] == book.id)) {
      return book;
    }
    return book.withProgress(local);
  }

  Future<CatalogPage> catalog(
    String kind, {
    int page = 0,
    String? search,
    String sort = 'metadata.titleSort,asc',
    Json? condition,
    String? path,
  }) async {
    final data = await get(
      path ?? '/api/v1/$kind/list',
      method: path == null ? 'POST' : 'GET',
      body: path == null
          ? {
              'condition': ?condition,
              if (search != null && search.isNotEmpty) 'fullTextSearch': search,
            }
          : null,
      query: {
        'page': page,
        'size': 40,
        if (!(path?.contains('/readlists/') == true &&
            path?.endsWith('/books') == true))
          'sort': sort,
        if (path != null && search != null && search.isNotEmpty)
          'search': search,
      },
    );
    final result = CatalogPage.parse(kind, data);
    if (kind != 'books') return result;
    return CatalogPage(
      result.items.map((v) {
        store.cache(profile.id, 'book:${v.id}', v.json);
        return CatalogItem(kind, overlay(v.book).json);
      }).toList(),
      result.last,
      result.total,
    );
  }

  Future<Book> book(String id) async {
    Book result;
    if (offline) {
      final value =
          store.cached(profile.id, 'book:$id') ??
          store.download(profile.id, id)?['book'];
      if (value == null) {
        throw const ApiFailure(
          'This book is not available offline.',
          offline: true,
        );
      }
      result = Book(object(value));
    } else {
      try {
        result = await api.book(id);
        store.cache(profile.id, 'book:$id', result.json);
      } on ApiFailure catch (e) {
        if (!e.offline) rethrow;
        final cached = store.cached(profile.id, 'book:$id');
        if (cached == null) rethrow;
        result = Book(object(cached));
      }
    }
    return overlay(result);
  }

  Future<Uint8List> image(String path, {bool refresh = false}) {
    if (refresh) _images.remove(path);
    return _images.putIfAbsent(path, () async {
      try {
        final file = cachedFile(path);
        if (!refresh && await file.exists()) return await file.readAsBytes();
        if (offline) {
          throw const ApiFailure('Image unavailable offline.', offline: true);
        }
        final bytes = await api.bytes(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return bytes;
      } finally {
        _images.remove(path);
      }
    });
  }

  Future<Uint8List> page(String id, int page) async {
    final file = pageFile(id, page);
    if (await file.exists()) return file.readAsBytes();
    return image('/api/v1/books/${Uri.encodeComponent(id)}/pages/$page');
  }

  void setProgress(Book book, int page, {bool? completed, bool reset = false}) {
    if (_disposed) return;
    if (page < 1 && !reset || page > book.pages && book.pages > 0) return;
    store.recordProgress(profile.id, book.id, {
      'page': page,
      'completed': completed ?? (book.pages > 0 && page == book.pages),
      'lastModified': DateTime.now().toUtc().toIso8601String(),
      if (reset) 'reset': true,
    });
    progressRevision++;
    changed();
    unawaited(sync());
  }

  void setEpubProgress(
    Book book,
    String href,
    double progression,
    double total,
  ) {
    if (_disposed) return;
    var device = store.setting<String>('deviceId');
    if (device == null) {
      device = sha256
          .convert(List.generate(32, (_) => Random.secure().nextInt(256)))
          .toString();
      store.setSetting('deviceId', device);
    }
    final timestamp = DateTime.now().toUtc().toIso8601String();
    store.recordProgress(profile.id, book.id, {
      'kind': 'epub',
      'lastModified': timestamp,
      'progression': {
        'modified': timestamp,
        'device': {
          'id': device,
          'name': 'KMReader ${Platform.operatingSystem}',
        },
        'locator': {
          'href': href,
          'type': 'application/xhtml+xml',
          'locations': {
            'fragments': <String>[],
            'progression': progression,
            'totalProgression': total,
          },
        },
      },
    });
    changed();
    unawaited(sync());
  }

  Future<Json> _epubProgression(String book, Json value) async {
    final key = 'positions:$book';
    var data = store.cached(profile.id, key);
    if (data == null) {
      data = await api.request(
        '/api/v1/books/${Uri.encodeComponent(book)}/positions',
        extra: {'Accept': 'application/vnd.readium.position-list+json'},
      );
      store.cache(profile.id, key, data);
    }
    final requested = object(value['locator']);
    final href = Uri.decodeComponent(text(requested['href']).split('#').first);
    final positions =
        (object(data)['positions'] as List? ?? []).map(object).where((v) {
          final candidate = Uri.decodeComponent(text(v['href']));
          return candidate == href || href.endsWith('/$candidate');
        }).toList()..sort(
          (a, b) => ((object(a['locations'])['progression'] as num?) ?? 0)
              .compareTo((object(b['locations'])['progression'] as num?) ?? 0),
        );
    if (positions.isEmpty) {
      throw const ApiFailure(
        'This chapter has no valid server reading positions.',
      );
    }
    final desired =
        (object(requested['locations'])['progression'] as num?)?.toDouble() ??
        0;
    final minimum =
        (object(positions.first['locations'])['progression'] as num?)
            ?.toDouble() ??
        0;
    final maximum =
        (object(positions.last['locations'])['progression'] as num?)
            ?.toDouble() ??
        0;
    final progression = desired.clamp(minimum, maximum);
    final selected = positions.lastWhere(
      (v) =>
          ((object(v['locations'])['progression'] as num?) ?? 0) <= progression,
      orElse: () => positions.first,
    );
    return {
      ...value,
      'locator': {
        ...selected,
        'locations': {
          ...object(selected['locations']),
          'fragments': object(selected['locations'])['fragments'] ?? <String>[],
          'progression': progression,
        },
      },
    };
  }

  Future<void> sync({bool force = false}) async {
    if (_syncing || offline || _disposed) return;
    _syncing = true;
    syncFailure = null;
    try {
      for (final row in store.pending(profile.id)) {
        final value = object(row['value']);
        try {
          final epub = value['kind'] == 'epub';
          final progression = epub
              ? await _epubProgression(
                  row['book'],
                  object(value['progression']),
                )
              : null;
          final path = '/api/v1/books/${Uri.encodeComponent(row['book'])}';
          Json remote = {};
          try {
            final result = object(
              await api.request(
                epub ? '$path/progression' : path,
                extra: epub
                    ? {'Accept': 'application/vnd.readium.progression+json'}
                    : null,
              ),
            );
            remote = epub ? result : object(result['readProgress']);
          } on ApiFailure catch (e) {
            if (e.status != 404) rethrow;
          }
          final remoteTime = DateTime.tryParse(
            text(remote[epub ? 'modified' : 'lastModified']),
          );
          final localTime = DateTime.tryParse(text(value['lastModified']));
          final ahead = epub
              ? ((object(
                              object(remote['locator'])['locations'],
                            )['totalProgression']
                            as num?) ??
                        0) >
                    ((object(
                              object(progression?['locator'])['locations'],
                            )['totalProgression']
                            as num?) ??
                        0)
              : integer(remote['page']) > integer(value['page']) ||
                    remote['completed'] == true && value['completed'] != true;
          if (!force &&
              ahead &&
              remoteTime != null &&
              localTime != null &&
              remoteTime.isAfter(localTime)) {
            conflicts[row['book']] = remote;
            syncFailure = 'Newer reading progress exists on the server. Resolve it in Settings.';
            continue;
          }
          if (epub) {
            await api.request(
              '$path/progression',
              method: 'PUT',
              body: progression,
            );
          } else {
            await api.request(
              '/api/v1/books/${Uri.encodeComponent(row['book'])}/read-progress',
              method: value['reset'] == true ? 'DELETE' : 'PATCH',
              body: value['reset'] == true
                  ? null
                  : {'page': value['page'], 'completed': value['completed']},
            );
          }
          if (_disposed) return;
          store.acknowledge(profile.id, row['book'], row['revision']);
          conflicts.remove(row['book']);
        } catch (e) {
          syncFailure = e.toString();
          break;
        }
      }
    } finally {
      _syncing = false;
      changed();
    }
    if (store.pending(profile.id).isNotEmpty &&
        !_disposed &&
        !offline &&
        conflicts.isEmpty) {
      _reconnect?.cancel();
      _reconnect = Timer(const Duration(seconds: 15), () => unawaited(sync()));
    }
  }

  void acceptServerProgress() {
    for (final entry in conflicts.entries) {
      final old = store.progress(profile.id, entry.key);
      final remote = old?['kind'] == 'epub'
          ? {
              'kind': 'epub',
              'progression': entry.value,
              'lastModified': entry.value['modified'],
            }
          : entry.value;
      store.recordProgress(profile.id, entry.key, remote);
      final row = store
          .pending(profile.id)
          .firstWhere((v) => v['book'] == entry.key);
      store.acknowledge(profile.id, entry.key, row['revision']);
    }
    conflicts.clear();
    syncFailure = null;
    refreshContent();
  }

  void setOffline(bool value) {
    offline = value;
    if (offline) {
      _eventReconnect?.cancel();
      _events?.cancel();
      _events = null;
    } else {
      unawaited(sync());
      listen();
    }
    changed();
  }

  void listen() {
    if (_disposed || offline || _events != null) return;
    _events = api.events().listen(
      (_) {
        _refreshTimer?.cancel();
        _refreshTimer = Timer(
          const Duration(milliseconds: 600),
          refreshContent,
        );
      },
      onError: (Object error) {
        _events = null;
        if (_disposed || offline) return;
        _eventReconnect?.cancel();
        _eventReconnect = Timer(const Duration(seconds: 10), listen);
      },
      onDone: () {
        _events = null;
        if (_disposed || offline) return;
        _eventReconnect?.cancel();
        _eventReconnect = Timer(const Duration(seconds: 10), listen);
      },
    );
  }

  Future<void> download(Book book) async {
    if (downloading.containsKey(book.id)) return;
    _cancelled.remove(book.id);
    downloading[book.id] = 0;
    store.saveDownload(profile.id, book, 'downloading');
    changed();
    try {
      try {
        await image('/api/v1/books/${Uri.encodeComponent(book.id)}/thumbnail');
      } catch (_) {}
      await api.download(
        '/api/v1/books/${Uri.encodeComponent(book.id)}/file',
        bookFile(book),
        progress: (count, total) {
          downloading[book.id] = total == null || total == 0
              ? 0
              : count / total * .5;
          changed();
        },
        cancelled: () => _cancelled.contains(book.id),
      );
      if (book.format == 'comic') {
        for (var i = 1; i <= book.pages; i++) {
          if (_cancelled.contains(book.id) || _disposed) {
            throw const ApiFailure('Download cancelled.');
          }
          final page = pageFile(book.id, i);
          if (!await page.exists()) {
            await api.download(
              '/api/v1/books/${Uri.encodeComponent(book.id)}/pages/$i',
              page,
              cancelled: () => _cancelled.contains(book.id),
            );
          }
          downloading[book.id] = .5 + .5 * i / book.pages;
          changed();
        }
      }
      var size = 0;
      await for (final file in bookDirectory(book.id).list()) {
        if (file is File) size += await file.length();
      }
      if (!_disposed) store.saveDownload(profile.id, book, 'ready', size: size);
    } catch (e) {
      if (!_disposed) {
        store.saveDownload(profile.id, book, 'failed', error: e.toString());
      }
      rethrow;
    } finally {
      downloading.remove(book.id);
      changed();
    }
  }

  void cancelDownload(String id) => _cancelled.add(id);
  Future<void> removeDownload(String id) async {
    if (downloading.containsKey(id)) {
      throw const ApiFailure('Cancel the active download first.');
    }
    final dir = bookDirectory(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    store.deleteDownload(profile.id, id);
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _events?.cancel();
    _refreshTimer?.cancel();
    _reconnect?.cancel();
    _eventReconnect?.cancel();
    _cancelled.addAll(downloading.keys);
    api.close();
    super.dispose();
  }
}
