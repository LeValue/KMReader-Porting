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
import 'cache.dart';

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
  int cacheRevision = 0;
  Timer? _cacheEvents;
  final catalogChanges = ValueNotifier<int>(0);
  final _queries = <String, Future<dynamic>>{};
  final _storedBookBatches = Expando<bool>();
  final _queryValues = WeightedCache<String, dynamic>(
    maxWeight: 8 * 1024 * 1024,
    weight: (value) => jsonEncode(value).length * 2,
  );
  final _queryDates = <String, DateTime>{};
  final _bytes = WeightedCache<String, Uint8List>(
    maxWeight: 32 * 1024 * 1024,
    weight: (value) => value.length,
  );
  final _imageRequests = ImageRequests();
  DateTime _invalidated = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _cacheTrim;
  DateTime _lastTrim = DateTime.fromMillisecondsSinceEpoch(0);
  Directory get imageDirectory =>
      Directory(p.join(directory.path, profile.id, 'cache'));
  void _scheduleTrim() {
    if (_disposed ||
        _cacheTrim != null ||
        DateTime.now().difference(_lastTrim) < const Duration(minutes: 1)) {
      return;
    }
    _cacheTrim = Timer(const Duration(seconds: 2), () async {
      _cacheTrim = null;
      _lastTrim = DateTime.now();
      try {
        await trimMediaCache(imageDirectory, 512 * 1024 * 1024);
      } on FileSystemException {
        /* Caching must not interrupt reading. */
      }
    });
  }

  Future<void> clearImageCache() async {
    _bytes.clear();
    await trimMediaCache(imageDirectory, 0);
    changed();
  }

  String? syncFailure;
  final Map<String, Json> conflicts = {};
  Timer? _eventReconnect;
  final Map<String, double> downloading = {};
  final Set<String> _cancelled = {};
  int get pendingCount => store.pendingCount(profile.id);
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
    _invalidated = DateTime.now();
    contentRevision++;
    catalogChanges.value++;
    changed();
  }

  Future<dynamic> get(
    String path, {
    String method = 'GET',
    dynamic body,
    Map<String, dynamic>? query,
    bool cacheFirst = false,
    bool force = false,
    String? cacheKey,
  }) async {
    final key = cacheKey ?? jsonEncode([path, method, body, query]);
    final memory = _queryValues[key];
    final cached = memory ?? store.cached(profile.id, key);
    if (memory == null && cached != null) _queryValues.put(key, cached);
    if (offline) {
      if (cached != null) return cached;
      throw const ApiFailure(
        'This content has not been saved for offline use.',
        offline: true,
      );
    }
    Future<dynamic> fetch({bool background = false}) =>
        _queries.putIfAbsent(key, () async {
          try {
            final value = await api.request(
              path,
              method: method,
              body: body,
              query: query,
            );
            if (_disposed) return value;
            final different =
                background && jsonEncode(cached) != jsonEncode(value);
            store.cache(profile.id, key, value);
            _queryValues.put(key, value);
            _queryDates[key] = DateTime.now();
            if (_queryDates.length > 256) {
              _queryDates.remove(_queryDates.keys.first);
            }
            if (different) {
              cacheRevision++;
              _cacheEvents ??= Timer(const Duration(milliseconds: 50), () {
                _cacheEvents = null;
                if (!_disposed) catalogChanges.value++;
              });
            }
            return value;
          } finally {
            _queries.remove(key);
          }
        });
    if (cacheFirst && cached != null && !force) {
      final date = _queryDates[key] ?? store.cachedAt(profile.id, key);
      if (date == null ||
          date.isBefore(_invalidated) ||
          DateTime.now().difference(date) > const Duration(seconds: 30)) {
        unawaited(fetch(background: true).catchError((Object _) => cached));
      }
      return cached;
    }
    try {
      return await fetch();
    } on ApiFailure catch (e) {
      if (!e.offline && (e.status == null || e.status! < 500)) rethrow;
      if (cached != null) return cached;
      rethrow;
    }
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
        !store.isPending(profile.id, book.id)) {
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
    bool force = false,
    int size = 40,
    String? libraryId,
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
        'size': size,
        'library_id': ?libraryId,
        if (!(path?.contains('/readlists/') == true &&
            path?.endsWith('/books') == true))
          'sort': sort,
        if (path != null && search != null && search.isNotEmpty)
          'search': search,
      },
      cacheFirst: true,
      force: force,
    );
    final result = CatalogPage.parse(kind, data);
    if (kind != 'books') return result;
    if ((data is Map || data is List) && _storedBookBatches[data] != true) {
      store.cacheBooks(profile.id, result.items);
      _storedBookBatches[data] = true;
    }
    return CatalogPage(
      result.items.map((v) {
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
        result = Book(
          object(
            await get(
              '/api/v1/books/${Uri.encodeComponent(id)}',
              cacheFirst: true,
              cacheKey: 'book:$id',
            ),
          ),
        );
      } on ApiFailure catch (e) {
        if (!e.offline) rethrow;
        final cached = store.cached(profile.id, 'book:$id');
        if (cached == null) rethrow;
        result = Book(object(cached));
      }
    }
    return overlay(result);
  }

  Future<Uint8List> image(String path, {bool refresh = false}) =>
      _image(path, refresh: refresh);
  Future<Uint8List> _image(
    String path, {
    bool refresh = false,
    bool speculative = false,
  }) {
    if (refresh) _bytes.remove(path);
    final cached = _bytes[path];
    if (!refresh && cached != null) return SynchronousFuture(cached);
    return _imageRequests.run(path, () async {
      final file = cachedFile(path);
      if (!refresh && await file.exists()) {
        try {
          final bytes = await file.readAsBytes();
          unawaited(
            file.setLastModified(DateTime.now()).catchError((Object _) => file),
          );
          _bytes.put(path, bytes);
          return bytes;
        } on FileSystemException {
          // A concurrent trim can remove an entry between lookup and read.
        }
      }
      if (offline) {
        throw const ApiFailure('Image unavailable offline.', offline: true);
      }
      final bytes = await api.bytes(path);
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(bytes);
      await partial.rename(file.path);
      if (!_disposed) _bytes.put(path, bytes);
      _scheduleTrim();
      return bytes;
    }, speculative: speculative);
  }

  Future<Uint8List> page(String id, int page) async {
    final path = '/api/v1/books/${Uri.encodeComponent(id)}/pages/$page';
    final memory = _bytes[path];
    if (memory != null) return memory;
    final file = pageFile(id, page);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      _bytes.put(path, bytes);
      return bytes;
    }
    return image(path);
  }

  Future<Uint8List> prefetchPage(String id, int number) async {
    if (await pageFile(id, number).exists()) return page(id, number);
    return _image(
      '/api/v1/books/${Uri.encodeComponent(id)}/pages/$number',
      speculative: true,
    );
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
    catalogChanges.value++;
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
    progressRevision++;
    catalogChanges.value++;
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
    _cacheEvents?.cancel();
    _cacheTrim?.cancel();
    _disposed = true;
    _events?.cancel();
    _refreshTimer?.cancel();
    _reconnect?.cancel();
    _eventReconnect?.cancel();
    _cancelled.addAll(downloading.keys);
    _imageRequests.close();
    _bytes.clear();
    _queryValues.clear();
    catalogChanges.dispose();
    api.close();
    super.dispose();
  }
}
