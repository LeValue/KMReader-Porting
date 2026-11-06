import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../api.dart';
import '../models.dart';
import '../repository.dart';
import '../store.dart';
import 'client.dart';
import 'conversion.dart';
import 'library.dart';
import 'positions.dart';

/// The existing catalog, cards, queue and reader consume this same interface.
/// Only the content provider differs; no separate Kindle reader or shell.
class KindleRepository extends Repository {
  factory KindleRepository({
    required ServerProfile profile,
    required LocalStore store,
    required Directory directory,
    required KindleClient client,
    KindlePreparation? preparation,
  }) {
    final library = KindleLibrary(
      client: client,
      store: store,
      directory: directory,
      profile: profile,
      preparation: preparation,
    );
    final api = _KindleApi(library);
    return KindleRepository._(library, profile, store, directory, api);
  }
  KindleRepository._(
    this.library,
    ServerProfile profile,
    LocalStore store,
    Directory directory,
    KomgaApi api,
  ) : super(profile: profile, api: api, store: store, directory: directory) {
    library.onPrepared = (id) {
      if (!closed) {
        invalidateImage('/api/v1/books/$id/thumbnail');
        localCatalogChanged();
      }
    };
    if (library.hasCatalog) library.index();
  }
  final KindleLibrary library;
  bool _synchronizing = false;
  Timer? _kindleTimer;
  String? _mappedBook;
  KindlePositionMap? _mapping;
  int _mappingGeneration = 0;
  final _verifiedSidecars = <String, Json>{};
  bool get kindleSyncEnabled =>
      store.setting<bool>('kindleSync:${profile.id}') != false;
  Json get _outbox => object(store.cached(profile.id, 'kindle:outbox'));
  void _saveOutbox(Json value) =>
      store.cache(profile.id, 'kindle:outbox', value);
  @override
  int get pendingCount =>
      super.pendingCount + (kindleSyncEnabled ? _outbox.length : 0);
  @override
  void dispose() {
    _kindleTimer?.cancel();
    super.dispose();
  }

  @override
  Future<Json?> externalDocumentPosition(Book book, File file) async {
    final generation = ++_mappingGeneration;
    if (!kindleSyncEnabled ||
        closed ||
        book.format != 'epub' ||
        store.setting<bool>('kindleMapped:${profile.id}:${book.id}') != true) {
      return null;
    }
    try {
      final mapping = await KindlePositionMap.open(file.path);
      if (closed ||
          generation != _mappingGeneration ||
          mapping == null ||
          mapping.entries.isEmpty)
        return null;
      _mapping = mapping;
      _mappedBook = book.id;
      final cachedSidecar = object(
        store.cached(profile.id, 'kindle:sidecar:${book.id}'),
      );
      final sidecar = offline
          ? (cachedSidecar.isEmpty
                ? <String, dynamic>{
                    'acr': mapping.acrs.firstOrNull ?? '',
                    'guid': '',
                  }
                : cachedSidecar)
          : await library.client.sidecar(library.item(book.id));
      if (closed || generation != _mappingGeneration || sidecar == null)
        return null;
      final matches = mapping.matches(sidecar);
      store.cache(profile.id, 'kindle:availability:${book.id}', {
        'mapped': true,
        'edition_matches': matches,
        'guid_available': text(sidecar['guid']).isNotEmpty,
      });
      if (!matches) return null;
      _verifiedSidecars.clear();
      _verifiedSidecars[book.id] = sidecar;
      if (!offline) {
        store.cache(profile.id, 'kindle:sidecar:${book.id}', sidecar);
      }
      final remote = kindleLastRead(sidecar);
      if (offline ||
          remote == null ||
          book.completed ||
          _outbox.containsKey(book.id)) {
        return null;
      }
      final saved = object(store.cached(profile.id, 'epub:${book.id}'));
      final localTime = DateTime.tryParse(text(saved['modified']));
      final remoteTime = kindleTimestamp(remote['time']);
      if (text(saved['cfi']).isNotEmpty &&
          localTime != null &&
          (remoteTime == null || !remoteTime.isAfter(localTime))) {
        return null;
      }
      return mapping.locator(integer(remote['position']));
    } on KindleFailure {
      return null;
    }
  }

  @override
  void documentPosition(Book book, Json event) {
    final position = event['kindlePosition'];
    final sidecar = _verifiedSidecars[book.id];
    if (!kindleSyncEnabled ||
        closed ||
        position is! int ||
        position < 0 ||
        _mappedBook != book.id ||
        _mapping?.locator(position) == null ||
        sidecar == null) {
      return;
    }
    final pending = _outbox;
    final existing = object(pending[book.id]);
    if (existing['position'] == position) return;
    final remote = kindleLastRead(sidecar);
    pending[book.id] = {
      'position': position,
      'time': DateTime.now().toUtc().toIso8601String(),
      'acr': text(sidecar['acr']),
      'acrs': _mapping!.acrs.toList(),
      'guid': text(sidecar['guid']),
      'base_position': remote?['position'],
      'not_before': DateTime.now().millisecondsSinceEpoch + 3000,
    };
    _saveOutbox(pending);
    _kindleTimer?.cancel();
    _kindleTimer = Timer(const Duration(seconds: 3), () {
      if (!closed) unawaited(sync());
    });
  }

  @override
  bool get supportsSeries => false;
  @override
  bool get supportsRemoteLists => false;
  @override
  File bookFile(Book book) =>
      File(p.join(bookDirectory(book.id).path, 'source.document'));
  @override
  void listen() {}
  @override
  Future<Book> resolveDocumentBook(Book book, File file) async =>
      await this.book(book.id);
  @override
  Future<Book> book(String id) async {
    final cached = store.cached(profile.id, 'book:$id');
    if (cached != null) return overlay(Book(object(cached)));
    if (!library.hasCatalog && !offline) await library.refresh();
    return overlay(Book(library.bookJson(library.item(id))));
  }

  @override
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
    List<String>? libraryIds,
  }) async {
    if (!library.hasCatalog && !offline || force && !offline) {
      await library.refresh();
    }
    if (libraryIds != null && libraryIds.isNotEmpty) {
      condition = {
        'allOf': [
          ?condition,
          {
            'anyOf': [
              for (final id in libraryIds)
                {
                  'libraryId': {'operator': 'is', 'value': id},
                },
            ],
          },
        ],
      };
    }
    if (kind != 'books') return CatalogPage([], true, 0);
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
          .map((item) => CatalogItem('books', overlay(item.book).json))
          .toList(),
      result.last,
      result.total,
    );
  }

  @override
  Future<dynamic> get(
    String path, {
    String method = 'GET',
    dynamic body,
    Map<String, dynamic>? query,
    bool cacheFirst = false,
    bool force = false,
    String? cacheKey,
  }) async {
    if (!library.hasCatalog && !offline) await library.refresh();
    return api.request(path, method: method, body: body, query: query);
  }

  @override
  void refreshContent() {
    if (offline) {
      super.refreshContent();
      return;
    }
    unawaited(
      library.refresh().then(
        (_) {
          if (!closed) {
            super.refreshContent();
          }
        },
        onError: (Object error) {
          if (!closed) {
            eventNotices.value = error.toString();
          }
        },
      ),
    );
  }

  @override
  Future<void> sync({bool force = false}) async {
    if (_synchronizing || closed) return;
    _synchronizing = true;
    try {
      // Reading state stays durable in the same SQLite progress tables. The
      // Kindle locator queue is handled separately from Komga's REST writes.
      for (final row in store.pending(profile.id)) {
        store.acknowledge(
          profile.id,
          row['book'] as String,
          row['revision'] as int,
        );
      }
      if (!offline && kindleSyncEnabled) {
        final pending = _outbox;
        for (final entry in pending.entries.toList()) {
          if (closed) break;
          final local = object(entry.value);
          if (!force &&
              integer(local['not_before']) >
                  DateTime.now().millisecondsSinceEpoch) {
            continue;
          }
          if (!force && conflicts.containsKey(entry.key)) continue;
          try {
            final item = library.item(entry.key);
            final sidecar = await library.client.sidecar(item);
            if (sidecar == null ||
                text(sidecar['guid']).isEmpty ||
                !(local['acrs'] as List? ?? [local['acr']]).any(
                  (id) => id == sidecar['guid'] || id == sidecar['acr'],
                ) ||
                text(local['guid']).isNotEmpty &&
                    sidecar['guid'] != local['guid']) {
              throw const KindleFailure('reading_edition_changed');
            }
            final remote = kindleLastRead(sidecar);
            final remoteTime = kindleTimestamp(remote?['time']),
                localTime = kindleTimestamp(local['time']);
            if (!force &&
                remote != null &&
                remote['position'] != local['position'] &&
                remote['position'] != local['base_position'] &&
                (remoteTime == null ||
                    localTime == null ||
                    remoteTime.isAfter(localTime))) {
              conflicts[entry.key] = remote;
              syncFailure = 'Newer reading progress exists on the server. Resolve it in Settings.';
              continue;
            }
            final after = remote?['position'] == local['position']
                ? sidecar
                : await library.client.pushPosition(
                    item,
                    text(sidecar['guid']),
                    integer(local['position']),
                  );
            if (closed) break;
            _verifiedSidecars[entry.key] = after;
            store.cache(profile.id, 'kindle:sidecar:${entry.key}', after);
            final latest = _outbox, current = object(_outbox[entry.key]);
            if (current['time'] == local['time']) {
              latest.remove(entry.key);
            } else if (current.isNotEmpty) {
              latest[entry.key] = {
                ...current,
                'base_position': local['position'],
              };
            }
            _saveOutbox(latest);
            conflicts.remove(entry.key);
            if (conflicts.isEmpty) syncFailure = null;
          } on KindleFailure catch (error) {
            if (!closed) syncFailure = error.toString();
          } catch (_) {
            if (!closed) syncFailure = 'Kindle: sync_response';
          }
        }
      }
      if (!closed) changed();
    } finally {
      _synchronizing = false;
      if (!closed && !offline && kindleSyncEnabled && _outbox.isNotEmpty) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final next = _outbox.values
            .map(object)
            .map((value) => integer(value['not_before']))
            .reduce((a, b) => a < b ? a : b);
        _kindleTimer?.cancel();
        _kindleTimer = Timer(
          Duration(
            milliseconds: next > now ? (next - now).clamp(100, 30000) : 30000,
          ),
          () {
            if (!closed) unawaited(sync());
          },
        );
      }
    }
  }

  @override
  void acceptServerProgress() {
    final pending = _outbox;
    for (final id in conflicts.keys) {
      pending.remove(id);
      final saved = object(store.cached(profile.id, 'epub:$id'));
      saved.remove('cfi');
      saved.remove('modified');
      store.cache(profile.id, 'epub:$id', saved);
    }
    _saveOutbox(pending);
    conflicts.clear();
    syncFailure = null;
    progressRevision++;
    catalogChanges.value++;
    changed();
  }
}

class _KindleApi extends KomgaApi {
  _KindleApi(this.library)
    : super(
        Uri.parse('https://kindle.invalid'),
        authentication: Authentication.apiKey,
        credential: '',
      );
  final KindleLibrary library;
  @override
  void close() {
    library.client.close();
    super.close();
  }

  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic body,
    Map<String, dynamic>? query,
    Map<String, String>? extra,
  }) async {
    if (method != 'GET' && !(method == 'POST' && path.endsWith('/list'))) {
      throw const ApiFailure('This action is unavailable for this account.');
    }
    if (path == '/api/v1/libraries') {
      return [
        if (library.items.any((item) => item['type'] == 'PDOC'))
          {
            'id': 'kindle-documents',
            'name': 'Documenti personali',
            'seriesCount': 0,
          },
        if (library.items.any((item) => item['type'] == 'EBOK'))
          {'id': 'kindle-books', 'name': 'Libri Kindle', 'seriesCount': 0},
      ];
    }
    final detail = RegExp(r'^/api/v1/books/([^/]+)$').firstMatch(path);
    if (detail != null) {
      final id = Uri.decodeComponent(detail[1]!);
      final cached = library.store.cached(library.profile.id, 'book:$id');
      return cached ?? library.bookJson(library.item(id));
    }
    if (path.endsWith('/progression')) return <String, dynamic>{};
    if (path.endsWith('/pages')) return <dynamic>[];
    if (path.contains('/client-settings/')) return <dynamic>[];
    if (RegExp(r'^/api/v1/(series|readlists|collections)').hasMatch(path)) {
      return {'content': <dynamic>[], 'last': true, 'totalElements': 0};
    }
    if (path.startsWith('/api/v1/metadata/')) return <dynamic>[];
    throw const ApiFailure(
      'This feature is unavailable for this account.',
      status: 404,
    );
  }

  @override
  Future<void> download(
    String path,
    File target, {
    void Function(int, int?)? progress,
    bool Function()? cancelled,
    Future<void>? abortTrigger,
  }) async {
    final match = RegExp(r'^/api/v1/books/([^/]+)/file$').firstMatch(path);
    if (match == null) throw const ApiFailure('This download is unavailable.');
    await library.download(
      Uri.decodeComponent(match[1]!),
      target,
      progress: progress,
      cancelled: cancelled,
      abortTrigger: abortTrigger,
    );
  }

  @override
  Future<({Uint8List? bytes, String? etag, String? modified, bool notModified})>
  mediaBytes(String path, {String? etag, String? modified}) async {
    final match = RegExp(r'^/api/v1/books/([^/]+)/thumbnail').firstMatch(path);
    if (match == null) {
      throw const ApiFailure('Cover unavailable.', status: 404);
    }
    final file = library.coverFile(Uri.decodeComponent(match[1]!));
    if (!await file.exists()) {
      throw const ApiFailure('Cover unavailable.', status: 404);
    }
    return (
      bytes: await file.readAsBytes(),
      etag: null,
      modified: null,
      notModified: false,
    );
  }
}
