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
import 'page_formats.dart';
import 'read_list_reading.dart';
import '../features/reader/page_upscaler.dart';

class Repository extends ChangeNotifier {
  Repository({
    required this.profile,
    required this.api,
    required this.store,
    required this.directory,
    this.cacheClock = DateTime.now,
    this.backgroundTransfer = false,
  });
  final ServerProfile profile;
  final KomgaApi api;
  final LocalStore store;
  final Directory directory;
  final bool backgroundTransfer;
  VoidCallback? onDownloadQueueChanged;
  bool Function()? canTransfer;
  final _transferOwner = sha256
      .convert(List.generate(32, (_) => Random.secure().nextInt(256)))
      .toString();
  final _activeTransfers = <String, Future<void>>{};
  final _pausing = <String>{};
  bool _downloadSuspended = false;
  final DateTime Function() cacheClock;
  late final PageUpscaler pageUpscaler = PageUpscaler(imageDirectory);
  bool offline = false;
  late final ReadListReading readLists = ReadListReading(this);
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
  final _queryGenerations = <String, int>{};
  int _invalidationGeneration = 0;
  void _stampQuery(String key, int generation) {
    _queryDates[key] = cacheClock();
    _queryGenerations[key] = generation;
    while (_queryDates.length > 256) {
      final oldest = _queryDates.keys.first;
      _queryDates.remove(oldest);
      _queryGenerations.remove(oldest);
    }
  }

  final _bytes = WeightedCache<String, Uint8List>(
    maxWeight: 32 * 1024 * 1024,
    weight: (value) => value.length,
  );
  final _imageRequests = ImageRequests();
  final _pageTypes = Expando<Map<int, String>>();
  final _pageConversions = <String, Future<Uint8List>>{};
  String _pagePath(String id, int number) {
    final base = '/api/v1/books/${Uri.encodeComponent(id)}/pages/$number';
    final metadataPath = '/api/v1/books/${Uri.encodeComponent(id)}/pages';
    final key = jsonEncode([metadataPath, 'GET', null, null]);
    var data = _queryValues[key];
    if (data == null) {
      data = store.cached(profile.id, key);
      if (data != null) _queryValues.put(key, data);
    }
    if (data is! List) return base;
    final types = _pageTypes[data] ??= {
      for (final entry in data.map(object))
        integer(entry['number']): text(entry['mediaType']),
    };
    final type = types[number];
    return type != null && type.isNotEmpty && !portablePageMediaType(type)
        ? '$base?convert=png'
        : base;
  }

  Future<Uint8List> _compatiblePage(
    String id,
    int number,
    Uint8List bytes, {
    bool speculative = false,
  }) {
    if (portablePageBytes(bytes)) return SynchronousFuture(bytes);
    final base = '/api/v1/books/${Uri.encodeComponent(id)}/pages/$number';
    return _pageConversions.putIfAbsent(base, () async {
      try {
        Uint8List converted;
        try {
          converted = await _image(
            '$base?convert=png',
            speculative: speculative,
          );
        } on ApiFailure catch (error) {
          if (error.offline) {
            throw const ApiFailure(
              'Reconnect once to convert this page for offline reading.',
              offline: true,
            );
          }
          rethrow;
        }
        if (!portablePageBytes(converted)) {
          throw const ApiFailure(
            'The server could not convert this page to a supported image format.',
          );
        }
        if (_disposed) return converted;
        _bytes.put(base, converted);
        for (final file in [
          cachedFile(base),
          if (await pageFile(id, number).exists()) pageFile(id, number),
        ]) {
          await file.parent.create(recursive: true);
          final partial = File('${file.path}.convert.part');
          await partial.writeAsBytes(converted);
          await partial.rename(file.path);
        }
        return converted;
      } finally {
        _pageConversions.remove(base);
      }
    });
  }

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
    await trimMediaCache(Directory('${imageDirectory.path}/upscaled'), 0);
    changed();
  }

  String? syncFailure;
  final Map<String, Json> conflicts = {};
  Timer? _eventReconnect;
  final Map<String, double> downloading = {};
  final Set<String> _cancelled = {};
  final _downloadQueue = <Book>[];
  final _downloadTasks = <String, Completer<void>>{};
  final _downloadAborts = <String, Completer<void>>{};
  int get downloadConcurrency =>
      (store.setting<int>('downloadConcurrency') ?? 2).clamp(1, 3);
  void setDownloadConcurrency(int value) {
    store.setSetting('downloadConcurrency', value.clamp(1, 3));
    _pumpDownloads();
    changed();
  }

  bool queued(String id) =>
      _downloadQueue.any((b) => b.id == id) ||
      !downloading.containsKey(id) &&
          [
            'queued',
            'downloading',
            'paused',
          ].contains(store.download(profile.id, id)?['status']);
  int get pendingCount => store.pendingCount(profile.id);
  bool get closed => _disposed;
  void _cancelEvents() {
    final subscription = _events;
    _events = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

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
    if (_disposed) return;
    if (readLists.enabled && !offline) unawaited(readLists.sync());
    _invalidated = cacheClock();
    _invalidationGeneration++;
    contentRevision++;
    catalogChanges.value++;
    changed();
  }

  late final Set<String> _removed =
      (store.setting<List<dynamic>>('removed:${profile.id}') ?? [])
          .whereType<String>()
          .toSet();
  void rememberItem(CatalogItem item) {
    if (_disposed) return;
    final key = item.kind == 'books'
        ? 'book:${item.id}'
        : 'detail:${item.kind}:${item.id}';
    store.cache(profile.id, key, item.json);
    _queryValues.put(key, item.json);
    _stampQuery(key, _invalidationGeneration);
  }

  void removeCatalogItem(String kind, String id) {
    if (_disposed) return;
    _removed.add('$kind:$id');
    store.offlineCatalog.remove(profile.id, kind, id);
    store.setSetting('removed:${profile.id}', _removed.toList());
    store.deleteCache(profile.id, 'detail:$kind:$id');
    refreshContent();
  }

  void localCatalogChanged() {
    if (_disposed) return;
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
          final generation = _invalidationGeneration;
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
            _stampQuery(key, generation);
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
      final generation = _queryGenerations[key];
      final invalid = generation != null
          ? generation != _invalidationGeneration
          : date == null || !date.isAfter(_invalidated);
      if (date == null ||
          invalid ||
          date.isAfter(cacheClock()) ||
          cacheClock().difference(date) > const Duration(seconds: 30)) {
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
    if (local['reset'] == true) return book.withProgress(null);
    final remoteDate = DateTime.tryParse(text(book.progress['lastModified']));
    final localDate = DateTime.tryParse(text(local['lastModified']));
    if (remoteDate != null &&
        localDate != null &&
        remoteDate.isAfter(localDate) &&
        !store.isPending(profile.id, book.id)) {
      return book;
    }
    if (local['kind'] == 'epub') {
      final total = object(
        object(object(local['progression'])['locator'])['locations'],
      )['totalProgression'];
      if (total is! num || !total.isFinite) return book;
      return book.withProgress({
        'page': total >= 1
            ? book.pages
            : (total * book.pages).floor().clamp(
                1,
                book.pages > 0 ? book.pages : 1,
              ),
        'completed': total >= 1,
        'lastModified': local['lastModified'],
      });
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
    if (offline &&
        ['books', 'series', 'collections', 'readlists'].contains(kind)) {
      try {
        final result = store.offlineCatalog.query(
          profile.id,
          kind,
          page: page,
          size: size,
          search: search,
          condition: condition,
          path: path,
          sort: sort,
          libraryId: libraryId,
        );
        return CatalogPage(
          result.items
              .where((item) => !_removed.contains('$kind:${item.id}'))
              .map(
                (item) => kind == 'books'
                    ? CatalogItem(kind, overlay(item.book).json)
                    : item,
              )
              .toList(),
          result.last,
          result.total,
        );
      } on ApiFailure {
        if (path == null) rethrow; /* Saved special server lists use the exact cached response below. */
      }
    }
    String? readStatus(Json? condition) {
      if (condition == null) return null;
      final status = object(condition['readStatus']);
      if (status['operator'] == 'is') return text(status['value']);
      for (final child in condition['allOf'] as List? ?? []) {
        final found = readStatus(object(child));
        if (found != null) return found;
      }
      return null;
    }

    final searchEndpoint =
        path == null ||
        path.startsWith('/api/v1/smart-lists/') &&
            (path.endsWith('/books') || path.endsWith('/series'));
    final data = await get(
      path ?? '/api/v1/$kind/list',
      method: searchEndpoint ? 'POST' : 'GET',
      body: searchEndpoint
          ? {
              'condition': ?condition,
              if (search != null && search.isNotEmpty) 'fullTextSearch': search,
            }
          : null,
      query: {
        'page': page,
        'size': size,
        if (path?.contains('/readlists/') == true &&
            path?.endsWith('/books') == true)
          'read_status': readStatus(condition),
        'library_id': ?libraryId,
        if (!(path?.contains('/readlists/') == true &&
            path?.endsWith('/books') == true))
          'sort': sortQuery(kind, sort),
        if (path != null && search != null && search.isNotEmpty)
          'search': search,
      },
      cacheFirst: true,
      force: force,
    );
    final parsed = CatalogPage.parse(kind, data);
    final kept = parsed.items
        .where((item) => !_removed.contains('$kind:${item.id}'))
        .toList();
    final result = CatalogPage(
      kept,
      parsed.last,
      (parsed.total - (parsed.items.length - kept.length)).clamp(0, 1 << 31),
    );
    if (kind == 'series' &&
        data is Object &&
        _storedBookBatches[data] != true) {
      store.cacheItems(profile.id, result.items);
      _storedBookBatches[data] = true;
    }
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

  bool metadataIndexing = false;
  int metadataIndexed = 0;
  bool _cancelMetadata = false;
  String? metadataIndexError;
  void cancelMetadataIndex() {
    _cancelMetadata = true;
  }

  Future<void> prepareOfflineCatalog() async {
    if (metadataIndexing || offline || _disposed) return;
    metadataIndexing = true;
    metadataIndexed = 0;
    _cancelMetadata = false;
    metadataIndexError = null;
    changed();
    try {
      await get('/api/v1/libraries', force: true);
      for (final kind in ['series', 'books', 'collections', 'readlists']) {
        final seen = <String>{};
        for (var page = 0; ; page++) {
          if (_disposed || _cancelMetadata || offline) return;
          final chunk = await catalog(
            kind,
            page: page,
            size: 200,
            force: true,
            path: ['collections', 'readlists'].contains(kind)
                ? '/api/v1/$kind'
                : null,
            sort: kind == 'books' || kind == 'series'
                ? 'metadata.titleSort,asc'
                : 'name,asc',
          );
          if (_disposed) return;
          store.cacheItems(profile.id, chunk.items);
          seen.addAll(chunk.items.map((v) => v.id));
          metadataIndexed += chunk.items.length;
          changed();
          if (chunk.last || chunk.items.isEmpty) break;
        }
        if (_cancelMetadata || _disposed || offline) return;
        final obsolete = store.db
            .select(
              'SELECT id FROM catalog_records WHERE server=? AND kind=?',
              [profile.id, kind],
            )
            .map((r) => r['id'] as String)
            .where((id) => !seen.contains(id))
            .toList();
        for (final id in obsolete) {
          store.offlineCatalog.remove(profile.id, kind, id);
        }
      }
      store.setSetting('offlineCatalogSnapshot:${profile.id}', {
        'modified': DateTime.now().toUtc().toIso8601String(),
        'items': metadataIndexed,
      });
      localCatalogChanged();
    } catch (error) {
      if (!_disposed) metadataIndexError = error.toString();
    } finally {
      metadataIndexing = false;
      if (!_disposed) changed();
    }
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
    final conversion = _pageConversions[path];
    if (conversion != null) return conversion;
    final memory = _bytes[path] ?? _bytes['$path?convert=png'];
    if (memory != null) return _compatiblePage(id, page, memory);
    final file = pageFile(id, page);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      _bytes.put(path, bytes);
      return _compatiblePage(id, page, bytes);
    }
    return _compatiblePage(id, page, await image(_pagePath(id, page)));
  }

  Future<Uint8List> prefetchPage(String id, int number) async {
    if (await pageFile(id, number).exists()) return page(id, number);
    final bytes = await _image(_pagePath(id, number), speculative: true);
    return _compatiblePage(id, number, bytes, speculative: true);
  }

  void setProgress(Book book, int page, {bool? completed, bool reset = false}) {
    if (_disposed) return;
    if (page < 1 && !reset && completed != true ||
        page > book.pages && book.pages > 0) {
      return;
    }
    store.recordProgress(profile.id, book.id, {
      'page': page,
      'completed': completed ?? (book.pages > 0 && page == book.pages),
      'lastModified': DateTime.now().toUtc().toIso8601String(),
      if (completed == true ||
          completed == null && book.pages > 0 && page == book.pages)
        'readDate': DateTime.now().toUtc().toIso8601String(),
      if (reset) 'reset': true,
    });
    progressRevision++;
    catalogChanges.value++;
    changed();
    unawaited(sync());
  }

  void markBooks(Iterable<Book> books, bool read) {
    if (_disposed) return;
    final timestamp = DateTime.now().toUtc().toIso8601String();
    store.recordProgressBatch(profile.id, {
      for (final book in books)
        book.id: {
          'page': read ? book.pages : 0,
          'completed': read,
          if (read) 'readDate': timestamp,
          'lastModified': timestamp,
          if (!read) 'reset': true,
        },
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
    double total, {
    String? cfi,
  }) {
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
            'fragments': <String>[if (cfi != null && cfi.isNotEmpty) cfi],
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
                  : {
                      if (integer(value['page']) > 0) 'page': value['page'],
                      'completed': value['completed'],
                    },
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
      for (final id in downloading.keys.toList()) {
        cancelDownload(id);
      }
      _eventReconnect?.cancel();
      _cancelEvents();
    } else {
      unawaited(sync());
      listen();
      _pumpDownloads();
    }
    changed();
  }

  void listen() {
    if (_disposed || offline || _events != null) return;
    _events = api.events().listen(
      (type) {
        if (type == 'TaskQueueStatus') {
          return;
        }
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

  Future<void> download(Book book) {
    if (_disposed) {
      return Future.error(
        const ApiFailure('The server connection was closed.'),
      );
    }
    final existing = _downloadTasks[book.id];
    if (existing != null) return existing.future;
    final task = Completer<void>();
    _downloadTasks[book.id] = task;
    _downloadQueue.add(book);
    if (!store.transferring(profile.id, book.id)) {
      store.saveDownload(profile.id, book, 'queued');
    }
    onDownloadQueueChanged?.call();
    changed();
    _pumpDownloads();
    return task.future;
  }

  void pauseDownloads() {
    _downloadSuspended = true;
    for (final book in _downloadTasks.keys.toList()) {
      _pausing.add(book);
      _cancelled.add(book);
      final abort = _downloadAborts[book];
      if (abort != null && !abort.isCompleted) abort.complete();
    }
    changed();
  }

  Future<void> stopDownloadWork() async {
    final active = _activeTransfers.values.toList();
    dispose();
    await Future.wait(active.map((f) => f.catchError((Object _) {})));
  }

  void resumeDownloads() {
    _downloadSuspended = false;
    for (final row in store.downloads(profile.id)) {
      if (['queued', 'downloading', 'paused'].contains(row['status'])) {
        unawaited(
          download(Book(object(row['book']))).catchError((Object _) {}),
        );
      }
    }
  }

  void _pumpDownloads() {
    if (_disposed ||
        offline ||
        _downloadSuspended ||
        !(canTransfer?.call() ?? true)) {
      return;
    }
    while (_activeTransfers.length < downloadConcurrency &&
        _downloadQueue.isNotEmpty) {
      final book = _downloadQueue.removeAt(0);
      // Read by id independently of mutations to the pending queue.
      final completion = _downloadTasks[book.id];
      if (completion == null) continue;
      var paused = false;
      final future = _downloadBook(book)
          .then<void>(
            (_) {
              if (!completion.isCompleted) completion.complete();
            },
            onError: (Object error, StackTrace stack) {
              if (error is _TransferPaused && !_disposed) {
                paused = true;
                _downloadQueue.add(book);
              } else if (!completion.isCompleted) {
                completion.completeError(error, stack);
              }
            },
          )
          .whenComplete(() {
            _activeTransfers.remove(book.id);
            if (!paused) _downloadTasks.remove(book.id);
            if (!_disposed) onDownloadQueueChanged?.call();
            _pumpDownloads();
          });
      _activeTransfers[book.id] = future;
    }
  }

  Future<void> _transferLease(Book book) async {
    while (true) {
      if (_disposed ||
          _cancelled.contains(book.id) ||
          store.accountRemoved(profile.id)) {
        throw const ApiFailure('Download cancelled.');
      }
      if (store.claimTransfer(profile.id, book.id, _transferOwner)) return;
      if (backgroundTransfer) throw const TransferBusy();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _downloadBook(Book book) async {
    _cancelled.remove(book.id);
    _pausing.remove(book.id);
    var leased = false;
    Timer? heartbeat;
    var lastStored = DateTime.fromMillisecondsSinceEpoch(0);
    void fraction() {
      if (!_disposed &&
          DateTime.now().difference(lastStored).inMilliseconds >= 300) {
        store.downloadFraction(profile.id, book.id, downloading[book.id] ?? 0);
        lastStored = DateTime.now();
      }
    }

    final abort = Completer<void>();
    _downloadAborts[book.id] = abort;
    try {
      await _transferLease(book);
      leased = true;
      if (store.download(profile.id, book.id)?['status'] == 'ready' &&
          await bookFile(book).exists()) {
        return;
      }
      if (_disposed) throw const ApiFailure('Download cancelled.');
      downloading[book.id] = 0;
      store.saveDownload(profile.id, book, 'downloading');
      changed();
      heartbeat = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (_disposed) return;
        final row = store.download(profile.id, book.id);
        if (store.accountRemoved(profile.id) || row?['status'] == 'cancelled') {
          _cancelled.add(book.id);
          if (!abort.isCompleted) abort.complete();
        } else if (timer.tick % 10 == 0) {
          store.refreshTransfer(profile.id, book.id, _transferOwner);
        }
      });
      try {
        await Future.any([
          image('/api/v1/books/${Uri.encodeComponent(book.id)}/thumbnail'),
          abort.future.then<Uint8List>(
            (_) => throw const ApiFailure('Download cancelled.'),
          ),
        ]);
      } catch (_) {}
      if (_cancelled.contains(book.id) || _disposed) {
        throw const ApiFailure('Download cancelled.');
      }
      if (!await bookFile(book).exists()) {
        await api.download(
          '/api/v1/books/${Uri.encodeComponent(book.id)}/file',
          bookFile(book),
          progress: (count, total) {
            downloading[book.id] = total == null || total == 0
                ? 0
                : count / total * .5;
            fraction();
            changed();
          },
          cancelled: () => _cancelled.contains(book.id),
          abortTrigger: abort.future,
        );
      }
      if (book.format == 'comic') {
        try {
          await get(
            '/api/v1/books/${Uri.encodeComponent(book.id)}/pages',
            cacheFirst: true,
          );
        } catch (_) {
          /* Page dimensions are optional; page downloads still work. */
        }
        var lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
        for (var i = 1; i <= book.pages; i++) {
          if (_cancelled.contains(book.id) || _disposed) {
            throw const ApiFailure('Download cancelled.');
          }
          final page = pageFile(book.id, i);
          if (!await page.exists()) {
            await api.download(
              _pagePath(book.id, i),
              page,
              cancelled: () => _cancelled.contains(book.id),
              abortTrigger: abort.future,
            );
          }
          final header = await page
              .openRead(0, 16)
              .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
          if (!portablePageBytes(header)) await this.page(book.id, i);
          downloading[book.id] = .5 + .5 * i / book.pages;
          if (DateTime.now().difference(lastNotification).inMilliseconds >=
                  100 ||
              i == book.pages) {
            fraction();
            changed();
            lastNotification = DateTime.now();
          }
        }
      }
      var size = 0;
      if (_cancelled.contains(book.id) || _disposed) {
        throw const ApiFailure('Download cancelled.');
      }
      await for (final file in bookDirectory(book.id).list()) {
        if (file is File &&
            !file.path.endsWith('.part') &&
            !file.path.endsWith('.part.json')) {
          size += await file.length();
        }
      }
      if (!_disposed) store.saveDownload(profile.id, book, 'ready', size: size);
    } catch (e) {
      if (!_disposed && leased) {
        store.saveDownload(
          profile.id,
          book,
          _pausing.contains(book.id)
              ? 'paused'
              : _cancelled.contains(book.id)
              ? 'cancelled'
              : 'failed',
          error: e.toString(),
        );
      }
      if (_pausing.contains(book.id)) throw const _TransferPaused();
      rethrow;
    } finally {
      heartbeat?.cancel();
      if (leased) {
        try {
          store.releaseTransfer(profile.id, book.id, _transferOwner);
        } catch (_) {
          /* A closed foreground profile leaves a bounded lease for recovery. */
        }
      }
      _pausing.remove(book.id);
      downloading.remove(book.id);
      _downloadAborts.remove(book.id);
      changed();
    }
  }

  void cancelDownload(String id) {
    _pausing.remove(id);
    _cancelled.add(id);
    final abort = _downloadAborts[id];
    if (abort != null && !abort.isCompleted) abort.complete();
    final active = _activeTransfers.containsKey(id);
    _downloadQueue.removeWhere((b) => b.id == id);
    final task = active ? null : _downloadTasks.remove(id);
    if (task != null && !task.isCompleted) {
      task.completeError(const ApiFailure('Download cancelled.'));
    }
    final row = store.download(profile.id, id);
    if (row != null &&
        ['queued', 'downloading', 'paused'].contains(row['status'])) {
      store.saveDownload(profile.id, Book(object(row['book'])), 'cancelled');
    }
    onDownloadQueueChanged?.call();
    changed();
  }

  Future<void> removeDownload(String id) async {
    if (downloading.containsKey(id) || _downloadQueue.any((b) => b.id == id)) {
      throw const ApiFailure('Cancel the active download first.');
    }
    for (var i = 0; store.transferring(profile.id, id) && i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (store.transferring(profile.id, id)) {
      throw const ApiFailure('Wait for the active download to stop.');
    }
    final dir = bookDirectory(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    store.deleteDownload(profile.id, id);
    onDownloadQueueChanged?.call();
    changed();
  }

  @override
  void dispose() {
    if (_disposed) return;
    pageUpscaler.close();
    _cacheEvents?.cancel();
    _cacheTrim?.cancel();
    _disposed = true;
    _cancelEvents();
    _refreshTimer?.cancel();
    _reconnect?.cancel();
    _eventReconnect?.cancel();
    _cancelled.addAll(downloading.keys);
    for (final abort in _downloadAborts.values) {
      if (!abort.isCompleted) abort.complete();
    }
    for (final book in _downloadQueue) {
      final task = _downloadTasks.remove(book.id);
      if (task != null && !task.isCompleted) {
        task.completeError(
          const ApiFailure('The server connection was closed.'),
        );
      }
    }
    _downloadQueue.clear();
    _imageRequests.close();
    _bytes.clear();
    _queryValues.clear();
    _queryDates.clear();
    _queryGenerations.clear();
    catalogChanges.dispose();
    api.close();
    super.dispose();
  }
}

class TransferBusy implements Exception {
  const TransferBusy();
}

class _TransferPaused implements Exception {
  const _TransferPaused();
}
