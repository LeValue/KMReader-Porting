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
  }
  final KindleLibrary library;
  @override
  Future<void> stopDownloadWork() async {
    final indexing = library.settled;
    await super.stopDownloadWork();
    await indexing;
  }

  Future<void>? _syncWork;
  Timer? _kindleTimer;
  String? _mappedBook;
  KindlePositionMap? _mapping;
  int _mappingGeneration = 0;
  final _verifiedSidecars = <String, Json>{};
  bool get kindleSyncEnabled =>
      store.setting<bool>('kindleSync:${profile.id}') != false;
  bool get kindleAnnotationsEnabled =>
      store.setting<bool>('kindleAnnotations:${profile.id}') != false;
  @override
  List<Json> documentAnnotations(Book book) => !kindleAnnotationsEnabled
      ? const []
      : (store.cached(profile.id, 'kindle:annotations:${book.id}') as List? ??
                [])
            .map(object)
            .toList();

  Future<void> refreshAnnotations() async {
    final id = _mappedBook, mapping = _mapping, generation = _mappingGeneration;
    if (id == null ||
        mapping == null ||
        !kindleAnnotationsEnabled ||
        offline ||
        closed) {
      return;
    }
    final sidecar = await library.client.sidecar(
      library.item(id),
      guid: mapping.primary,
      annotations: true,
    );
    if (closed ||
        generation != _mappingGeneration ||
        sidecar == null ||
        !mapping.matches(sidecar)) {
      return;
    }
    store.cache(profile.id, 'kindle:sidecar:$id', sidecar);
    _importAnnotations(await book(id), mapping, sidecar);
  }

  void _importAnnotations(Book book, KindlePositionMap mapping, Json sidecar) {
    if (!kindleAnnotationsEnabled ||
        sidecar['annotations_loaded'] != true ||
        !mapping.matches(sidecar)) {
      return;
    }
    final values = <Json>[];
    for (final record in (sidecar['records'] as List? ?? []).map(object)) {
      final type = text(record['type']);
      if (!const {
        'kindle.bookmark',
        'kindle.highlight',
        'kindle.note',
      }.contains(type)) {
        continue;
      }
      final position = int.tryParse('${record['startPosition']}');
      if (position == null || text(record['annotationId']).isEmpty) continue;
      final locator = mapping.locator(position);
      if (locator == null) continue;
      final end = int.tryParse('${record['endPosition']}');
      final note = text(
        record['noteText'],
        text(record['text'], text(record['note'])),
      );
      final endLocator = end != null && end > position
          ? mapping.locator(end - 1)
          : null;
      values.add({
        'id': 'kindle:${record['annotationId']}',
        'source': 'kindle',
        'type': type,
        'href': locator['href'],
        'locator': locator,
        if (endLocator != null)
          'endLocator': {
            ...endLocator,
            'offset': integer(endLocator['offset']) + 1,
          },
        'label': note.isNotEmpty
            ? note
            : switch (type) {
                'kindle.note' => 'Nota Kindle',
                'kindle.highlight' => 'Evidenziazione Kindle',
                _ => 'Segnalibro Kindle',
              },
        'created': record['creationTime'],
        'modified': record['lastModificationTime'],
      });
    }
    store.cache(profile.id, 'kindle:annotations:${book.id}', values);
    documentAnnotationChanges.value++;
  }

  Json get _outbox => object(store.cached(profile.id, 'kindle:outbox'));
  void _saveOutbox(Json value) =>
      store.cache(profile.id, 'kindle:outbox', value);
  Map<String, Json> get readingConflicts {
    if (!kindleSyncEnabled) return {};
    final pending = _outbox;
    return {
      for (final entry in conflicts.entries)
        if (entry.value['pending_time'] != null &&
            entry.value['pending_time'] == object(pending[entry.key])['time'])
          entry.key: entry.value,
    };
  }

  String readingConflictTitle(String id) {
    final saved = object(store.cached(profile.id, 'book:$id'));
    if (saved.isNotEmpty) return Book(saved).title;
    try {
      return text(library.item(id)['title']);
    } on KindleFailure {
      return '';
    }
  }

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
    _mappedBook = null;
    _mapping = null;
    if ((!kindleSyncEnabled &&
            !kindleAnnotationsEnabled &&
            _resumeChoice(book.id).isEmpty) ||
        closed ||
        book.format != 'epub') {
      return null;
    }
    try {
      final mapping = await KindlePositionMap.open(file.path);
      if (closed ||
          generation != _mappingGeneration ||
          mapping == null ||
          mapping.acrs.isEmpty ||
          mapping.entries.isEmpty) {
        return null;
      }
      _mapping = mapping;
      _mappedBook = book.id;
      final cachedSidecar = object(
        store.cached(profile.id, 'kindle:sidecar:${book.id}'),
      );
      // Preserve original positions even when a book opens without a working
      // connection. A fresh matching server GUID is still required before any
      // queued position can be sent; these local placeholders never authorize
      // an Amazon write on their own.
      _verifiedSidecars
        ..clear()
        ..[book.id] = mapping.matches(cachedSidecar)
            ? cachedSidecar
            : <String, dynamic>{'acr': mapping.primary, 'guid': ''};
      final chosen = _chosenKindlePosition(book.id, mapping);
      if (chosen != null) {
        _importAnnotations(book, mapping, cachedSidecar);
        return chosen;
      }
      if (offline) {
        _importAnnotations(book, mapping, cachedSidecar);
        return null;
      }
      return await _readDocumentPosition(
        book,
        mapping,
        generation,
        opening: true,
      );
    } on KindleFailure {
      return null;
    }
  }

  @override
  bool canApplyDocumentPosition(Book book) =>
      !closed &&
      !offline &&
      kindleSyncEnabled &&
      _mappedBook == book.id &&
      _canReplacePendingPosition(book.id) &&
      !overlay(book).completed;

  bool _canReplacePendingPosition(String id) {
    final pending = _outbox[id];
    if (pending == null) return true;
    final revision = object(pending)['time'];
    return _syncWork == null &&
        revision != null &&
        conflicts[id]?['pending_time'] == revision;
  }

  @override
  Future<Json?> refreshDocumentPosition(Book book) async {
    final mapping = _mapping;
    if (mapping == null || !canApplyDocumentPosition(book)) return null;
    return _chosenKindlePosition(book.id, mapping) ??
        await _readDocumentPosition(book, mapping, _mappingGeneration);
  }

  Json _resumeChoice(String id) => object(
    object(store.cached(profile.id, 'epub:$id'))['kindleResumeChoice'],
  );

  Json? _chosenKindlePosition(String id, KindlePositionMap mapping) {
    final choice = _resumeChoice(id);
    if (choice['position'] is! int ||
        !mapping.acrs.contains(choice['edition']) ||
        _outbox.containsKey(id)) {
      return null;
    }
    final locator = mapping.locator(integer(choice['position']));
    return locator == null
        ? null
        : {...locator, 'modified': choice['time'], 'acceptedConflict': true};
  }

  Json? _cloudReadBaseline(String id, KindlePositionMap mapping) {
    final cached = object(store.cached(profile.id, 'kindle:cloud-read:$id'));
    if (cached['edition'] == mapping.primary && cached['read'] is Map) {
      return object(cached['read']);
    }
    final legacy = object(store.cached(profile.id, 'kindle:sidecar:$id'));
    return mapping.matches(legacy) ? kindleLastRead(legacy) : null;
  }

  void _rememberCloudRead(String id, String? edition, Json read) {
    if (edition == null) return;
    final key = 'kindle:cloud-read:$id';
    final cached = object(store.cached(profile.id, key));
    final prior = object(cached['read']);
    if (cached['edition'] == edition &&
        prior['position'] == read['position'] &&
        prior['time'] == read['time']) {
      return;
    }
    store.cache(profile.id, key, {'edition': edition, 'read': read});
  }

  @override
  void externalDocumentPositionApplied(Book book, Json locator) {
    final mapping = _mapping;
    if (mapping == null || !canApplyDocumentPosition(book)) return;
    final pending = _outbox;
    if (pending.remove(book.id) != null) {
      _saveOutbox(pending);
      conflicts.remove(book.id);
      if (conflicts.isEmpty) syncFailure = null;
    }
    _rememberCloudRead(book.id, mapping.primary, {
      'position': integer(locator['position']) + integer(locator['offset']),
      'time': locator['modified'],
    });
  }

  Future<Json?> _readDocumentPosition(
    Book book,
    KindlePositionMap mapping,
    int generation, {
    bool opening = false,
  }) async {
    final item = library.item(book.id);
    final (edition, account) = await (
      library.client
          .sidecar(
            item,
            guid: mapping.primary,
            annotations: opening && kindleAnnotationsEnabled,
          )
          .onError<KindleFailure>((_, _) => null),
      kindleSyncEnabled
          ? library.client.accountPositionSidecar(item)
          : Future<Json?>.value(),
    ).wait;
    if (closed || offline || generation != _mappingGeneration) {
      return null;
    }
    final sidecar = edition != null && mapping.matches(edition)
        ? edition
        : null;
    final accountMatch = account != null && mapping.matches(account)
        ? account
        : null;
    final baseline = _cloudReadBaseline(book.id, mapping);
    final availabilityKey = 'kindle:availability:${book.id}';
    final availability = {
      'mapped': true,
      'edition_matches': sidecar != null || accountMatch != null,
      'guid_available': text((sidecar ?? accountMatch)?['guid']).isNotEmpty,
    };
    final lastAvailability = object(store.cached(profile.id, availabilityKey));
    if (availability.entries.any(
      (entry) => lastAvailability[entry.key] != entry.value,
    )) {
      store.cache(profile.id, availabilityKey, availability);
    }
    if (sidecar != null) _verifiedSidecars[book.id] = sidecar;
    // Polling uses a position-only snapshot. Keep the persisted annotations
    // intact and save the new reading locator only after the reader applies it.
    if (opening && sidecar != null) {
      _importAnnotations(book, mapping, sidecar);
      store.cache(profile.id, 'kindle:sidecar:${book.id}', sidecar);
    }
    final remote = kindleLastRead(sidecar, account: accountMatch);
    if (remote == null || !canApplyDocumentPosition(book)) return null;
    final locator = mapping.locator(integer(remote['position']));
    if (locator == null) return null;
    final offer = {...locator, 'modified': remote['time']};
    final conflict = conflicts[book.id];
    if (conflict?['position'] == remote['position'] &&
        conflict?['time'] == remote['time']) {
      // Sync already compared this record to the pending edit's cloud base.
      // A cached snapshot or device time must not veto that same conflict.
      return offer;
    }

    final saved = object(store.cached(profile.id, 'epub:${book.id}'));
    final localTime = DateTime.tryParse(text(saved['modified']));
    final remoteTime = kindleTimestamp(remote['time']);
    final previousTime = kindleTimestamp(baseline?['time']);
    if (previousTime != null &&
        (remoteTime == null || remoteTime.isBefore(previousTime))) {
      return null;
    }
    final changedPosition = remote['position'] != baseline?['position'];
    if (previousTime != null && remoteTime == previousTime && changedPosition) {
      final latestAccount = kindleLastRead(accountMatch);
      if (latestAccount?['position'] != remote['position'] ||
          latestAccount?['time'] != remote['time']) {
        return null;
      }
    }
    // Once a matching cloud record has been seen, its changes can be compared
    // in Amazon's clock domain. Local EPUB saves include millisecond precision
    // and may come from a device whose clock is ahead of Amazon.
    final cloudMoved =
        baseline != null &&
        remoteTime != null &&
        (previousTime == null ||
            remoteTime.isAfter(previousTime) ||
            changedPosition);
    if (localTime != null &&
        (remoteTime == null || !remoteTime.isAfter(localTime)) &&
        !cloudMoved) {
      _rememberCloudRead(book.id, mapping.primary, remote);
      return null;
    }
    return offer;
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
    final remote =
        _cloudReadBaseline(book.id, _mapping!) ?? kindleLastRead(sidecar);
    pending[book.id] = {
      'position': position,
      'time': DateTime.now().toUtc().toIso8601String(),
      'acr': text(sidecar['acr']),
      'acrs': _mapping!.acrs.toList(),
      'guid': text(sidecar['guid']),
      'target_guid': _mapping!.primary,
      'base_position': existing.isEmpty
          ? (remote?['position'])
          : existing['base_position'],
      'base_time': existing.isEmpty ? (remote?['time']) : existing['base_time'],
      'not_before': DateTime.now().millisecondsSinceEpoch + 3000,
    };
    _saveOutbox(pending);
    if (conflicts.remove(book.id) != null && conflicts.isEmpty) {
      syncFailure = null;
    }
    _kindleTimer?.cancel();
    _kindleTimer = Timer(const Duration(seconds: 3), () {
      if (!closed) unawaited(sync());
    });
  }

  @override
  bool get offlineMetadataComplete =>
      library.hasCatalog && library.snapshot['complete'] == true;
  @override
  bool get supportsSeries => false;
  @override
  bool get prefetchDownloadCover => false;
  @override
  bool get supportsRemoteLists => false;
  @override
  File bookFile(Book book) =>
      File(p.join(bookDirectory(book.id).path, 'source.document'));
  @override
  void listen() {
    if (offline ||
        store.setting<bool>('kindleAutoRefresh:${profile.id}') == false) {
      return;
    }
    unawaited(
      library.initialize().then(
        (_) {
          if (closed || offline) return;
          final value = library.snapshot['fetched_at'];
          final fetched =
              DateTime.tryParse('$value')?.millisecondsSinceEpoch ??
              integer(value) * 1000;
          if (library.snapshot['dictionary_filter_version'] != 1 ||
              DateTime.now().millisecondsSinceEpoch - fetched >
                  15 * 60 * 1000) {
            refreshContent();
          }
        },
        onError: (Object error) {
          if (!closed) eventNotices.value = error.toString();
        },
      ),
    );
  }

  @override
  Future<Book> resolveDocumentBook(Book book, File file) async =>
      await this.book(book.id);
  @override
  Future<Book> book(String id) async {
    await library.ready;
    if (!library.hasCatalog && !offline) await library.refresh();
    library.item(id);
    final cached = store.cached(profile.id, 'book:$id');
    if (cached != null) return overlay(Book(object(cached)));
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
    await library.ready;
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
    await library.ready;
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
  Future<void> sync({bool force = false}) =>
      _syncWork ?? _startSync(force: force);

  Future<void> _startSync({required bool force, (String, Object?)? target}) =>
      _syncWork = _performSync(force, target).whenComplete(() {
        _syncWork = null;
      });

  Future<void> _performSync(bool force, (String, Object?)? target) async {
    if (closed) return;
    try {
      await library.initialize();
      if (closed) return;
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
          if (target != null && target != (entry.key, local['time'])) continue;
          if (!force &&
              integer(local['not_before']) >
                  DateTime.now().millisecondsSinceEpoch) {
            continue;
          }
          final conflict = conflicts[entry.key];
          if (!force &&
              conflict != null &&
              conflict['pending_time'] == local['time']) {
            continue;
          }
          try {
            final item = library.item(entry.key);
            final acrs = local['acrs'] as List? ?? [local['acr']];
            bool matches(Json sidecar) =>
                acrs.any((id) => id == sidecar['guid'] || id == sidecar['acr']);
            final accountRequest = library.client.accountPositionSidecar(item);
            final sidecar = await library.client.sidecar(
              item,
              guid: text(local['target_guid'], text(local['guid'])),
              annotations: kindleAnnotationsEnabled,
            );
            if (sidecar == null ||
                text(sidecar['guid']).isEmpty ||
                !matches(sidecar) ||
                text(local['guid']).isNotEmpty &&
                    sidecar['guid'] != local['guid']) {
              throw const KindleFailure('reading_edition_changed');
            }
            final account = await accountRequest;
            if (closed || offline || !kindleSyncEnabled) break;
            if (object(_outbox[entry.key])['time'] != local['time']) continue;
            final remote = kindleLastRead(
              sidecar,
              account: account != null && matches(account) ? account : null,
            );
            final cachedSidecar = object(
              store.cached(profile.id, 'kindle:sidecar:${entry.key}'),
            );
            final cachedRead = matches(cachedSidecar)
                ? kindleLastRead(cachedSidecar)
                : null;
            final remoteTime = kindleTimestamp(remote?['time']),
                comparisonTime =
                    kindleTimestamp(local['base_time']) ??
                    (cachedRead?['position'] == local['base_position']
                        ? kindleTimestamp(cachedRead?['time'])
                        : null) ??
                    kindleTimestamp(local['time']);
            if (!force &&
                remote != null &&
                remote['position'] != local['position'] &&
                remote['position'] != local['base_position'] &&
                (remoteTime == null ||
                    comparisonTime == null ||
                    !remoteTime.isBefore(comparisonTime))) {
              conflicts[entry.key] = {...remote, 'pending_time': local['time']};
              syncFailure = 'Newer reading progress exists on the server. Resolve it in Settings.';
              continue;
            }
            final alreadyConfirmed = remote?['position'] == local['position'];
            final after = alreadyConfirmed
                ? sidecar
                : await library.client.pushPosition(
                    item,
                    text(sidecar['guid']),
                    integer(local['position']),
                    annotations: kindleAnnotationsEnabled,
                  );
            if (closed) break;
            final confirmed = alreadyConfirmed ? remote : kindleLastRead(after);
            if (confirmed != null) {
              _rememberCloudRead(
                entry.key,
                text(local['target_guid'], text(local['guid'])),
                confirmed,
              );
            }
            _verifiedSidecars[entry.key] = after;
            store.cache(profile.id, 'kindle:sidecar:${entry.key}', after);
            final latest = _outbox, current = object(_outbox[entry.key]);
            if (current['time'] == local['time']) {
              latest.remove(entry.key);
            } else if (current.isNotEmpty) {
              latest[entry.key] = {
                ...current,
                'base_position': local['position'],
                'base_time': confirmed?['time'],
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

  bool useKindlePosition(String id, Json conflict) {
    if (closed || _syncWork != null || readingConflicts[id] != conflict) {
      return false;
    }
    final pending = _outbox;
    final local = object(pending[id]);
    final edition = text(local['target_guid'], text(local['acr']));
    if (edition.isEmpty || conflict['position'] is! int) return false;
    store.transaction(() {
      pending.remove(id);
      _saveOutbox(pending);
      final key = 'epub:$id';
      store.cache(profile.id, key, {
        ...object(store.cached(profile.id, key)),
        'kindleResumeChoice': {
          'position': conflict['position'],
          'time': conflict['time'],
          'edition': edition,
        },
      });
      _rememberCloudRead(id, edition, {
        'position': conflict['position'],
        'time': conflict['time'],
      });
    });
    conflicts.remove(id);
    if (conflicts.isEmpty) syncFailure = null;
    changed();
    return true;
  }

  Future<bool> sendDevicePosition(String id, Json conflict) async {
    await _syncWork;
    if (closed ||
        offline ||
        _syncWork != null ||
        readingConflicts[id] != conflict) {
      return false;
    }
    await _startSync(force: true, target: (id, conflict['pending_time']));
    return !_outbox.containsKey(id);
  }

  @override
  void acceptServerProgress() {
    for (final entry in readingConflicts.entries) {
      useKindlePosition(entry.key, entry.value);
    }
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
    library.close();
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
    await library.ready;
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
      library.item(id);
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
    final file = await library.cover(Uri.decodeComponent(match[1]!));
    if (file == null) {
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
