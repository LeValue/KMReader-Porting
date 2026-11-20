import 'dart:async';
import 'dart:convert';
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
  Timer? _kindleTimer, _annotationTimer;
  DateTime? _annotationsFetched;
  String? _mappedBook;
  KindlePositionMap? _mapping;
  int _mappingGeneration = 0;
  final _verifiedSidecars = <String, Json>{};
  bool get kindleSyncEnabled =>
      store.setting<bool>('kindleSync:${profile.id}') != false;
  bool get kindleAnnotationsEnabled =>
      store.setting<bool>('kindleAnnotations:${profile.id}') != false;
  @override
  List<Json> documentAnnotations(Book book) {
    if (!kindleAnnotationsEnabled) return const [];
    final hidden = object(
      store.cached(profile.id, 'kindle:annotation-removals:${book.id}'),
    );
    return [
      for (final mark
          in (store.cached(profile.id, 'kindle:annotations:${book.id}')
                      as List? ??
                  [])
              .map(object))
        if (!hidden.containsKey(
              _annotationKey(
                book.id,
                text(mark['type']).split('.').last,
                mark['kindleStart'],
                mark['kindleEnd'],
              ),
            ) &&
            !hidden.containsKey(text(mark['id'])))
          mark,
    ];
  }

  String _annotationKey(String book, String type, Object? start, Object? end) =>
      '$book:$type:$start:${end ?? ''}';

  void _reconcileRemoval(
    String book,
    String key,
    String? deletedId, {
    bool pending = false,
  }) {
    final cacheKey = 'kindle:annotation-removals:$book';
    final removed = object(store.cached(profile.id, cacheKey))..remove(key);
    if (pending) removed[key] = true;
    if (deletedId != null) removed[deletedId] = key;
    // Keep a small record of confirmed remote IDs to suppress delayed reads
    // from older sidecar replicas. Explicitly re-adding this range clears it.
    final confirmations = removed.entries
        .where((entry) => entry.value is String)
        .toList();
    for (final entry in confirmations.take(
      (confirmations.length - 512).clamp(0, confirmations.length),
    )) {
      removed.remove(entry.key);
    }
    store.cache(profile.id, cacheKey, removed);
    documentAnnotationChanges.value++;
  }

  void _allowNewAnnotation(String book, String key) {
    final cacheKey = 'kindle:annotation-removals:$book';
    final removed = object(store.cached(profile.id, cacheKey));
    final count = removed.length;
    removed.removeWhere((id, range) => id == key || range == key);
    if (count != removed.length) {
      store.cache(profile.id, cacheKey, removed);
      documentAnnotationChanges.value++;
    }
  }

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
    _importAnnotations(id, mapping, sidecar);
  }

  void _importAnnotations(String id, KindlePositionMap mapping, Json sidecar) {
    if (!kindleAnnotationsEnabled ||
        sidecar['annotations_available'] != true ||
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
      final note = kindleNoteText(record);
      final endLocator = end != null && end > position
          ? mapping.locator(end - 1)
          : null;
      values.add({
        'id': 'kindle:${record['annotationId']}',
        'source': 'kindle',
        'type': type,
        'href': locator['href'],
        'locator': locator,
        'kindleStart': position,
        'kindleEnd': ?end,
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
    final key = 'kindle:annotations:$id';
    if (store.cachedEncoded(profile.id, key) == jsonEncode(values)) return;
    store.cache(profile.id, key, values);
    documentAnnotationChanges.value++;
  }

  Json get _outbox => object(store.cached(profile.id, 'kindle:outbox'));
  void _saveOutbox(Json value) =>
      store.cache(profile.id, 'kindle:outbox', value);
  Json get _annotationOutbox =>
      object(store.cached(profile.id, 'kindle:annotation-outbox'));

  void _setAnnotationEdit(String key, Json? value) {
    final pending = _annotationOutbox;
    if (value == null) {
      pending.remove(key);
    } else {
      pending[key] = value;
    }
    store.cache(profile.id, 'kindle:annotation-outbox', pending);
  }

  @override
  void documentBookmark(Book book, int position, {required bool present}) =>
      _queueAnnotation(book, KindleMark('bookmark', position), present);

  @override
  void documentAnnotation(Book book, Json annotation, {required bool present}) {
    final mark = _editableMark(annotation);
    if (mark != null) {
      _queueAnnotation(
        book,
        mark,
        present,
        cloudId: annotation['source'] == 'kindle'
            ? text(annotation['id'])
            : null,
      );
    }
  }

  KindleMark? _editableMark(Json annotation) {
    final start = annotation['kindleStart'], end = annotation['kindleEnd'];
    if (start is! int || end is! int) return null;
    final type = text(annotation['type']);
    if (!const {'kindle.note', 'kindle.highlight'}.contains(type)) return null;
    return KindleMark(
      type.substring('kindle.'.length),
      start,
      end: end,
      note: type == 'kindle.note' ? text(annotation['label']) : null,
    );
  }

  @override
  bool canDeleteDocumentAnnotation(Book book, Json annotation) {
    final mark = _editableMark(annotation);
    return !closed &&
        kindleAnnotationsEnabled &&
        book.json['kindleType'] == 'PDOC' &&
        _mappedBook == book.id &&
        mark?.deletable == true;
  }

  void _queueAnnotation(
    Book book,
    KindleMark mark,
    bool present, {
    String? cloudId,
  }) {
    final mapping = _mapping;
    if (closed ||
        present && !kindleAnnotationsEnabled ||
        book.json['kindleType'] != 'PDOC' ||
        _mappedBook != book.id ||
        mapping == null ||
        !(present ? mark.valid : mark.valid || mark.deletable) ||
        mapping.locator(mark.start) == null ||
        mark.end != null && mapping.locator(mark.end! - 1) == null) {
      return;
    }
    final key = _annotationKey(book.id, mark.type, mark.start, mark.end);
    final existing = object(_annotationOutbox[key]);
    if (present && existing['submitted'] == true) return;
    if (!present && !mark.deletable) {
      if (existing.isNotEmpty && existing['submitted'] != true) {
        _setAnnotationEdit(key, null);
        changed();
      }
      return;
    }
    final erase = !present;
    final known = documentAnnotations(book)
        .where(
          (cached) =>
              _annotationKey(
                book.id,
                text(cached['type']).split('.').last,
                cached['kindleStart'],
                cached['kindleEnd'],
              ) ==
              key,
        )
        .firstOrNull;
    final id = cloudId ?? (known == null ? null : text(known['id']));
    if (erase && existing['erase'] == true) return;
    final waitForCreate = erase && existing['submitted'] == true && id == null;
    _setAnnotationEdit(key, {
      'book': book.id,
      'type': mark.type,
      'start': mark.start,
      'end': ?mark.end,
      if (present) 'note': ?mark.note,
      'edition': mapping.primary,
      'acrs': mapping.acrs.toList(),
      'revision': DateTime.now().microsecondsSinceEpoch,
      if (erase) 'erase': true,
      if (erase) 'cloudId': ?id,
      if (waitForCreate)
        'settleAfter': DateTime.now()
            .add(const Duration(minutes: 2))
            .millisecondsSinceEpoch,
    });
    if (erase) {
      _reconcileRemoval(book.id, key, null, pending: true);
    } else {
      _allowNewAnnotation(book.id, key);
    }
    changed();
    // Start after the local annotation transaction commits.
    unawaited(
      Future<void>(() async {
        await _syncWork;
        if (!closed && !offline) await sync();
      }),
    );
  }

  Future<void> _syncAnnotations() async {
    if (offline || closed || !kindleAnnotationsEnabled) return;
    for (final entry in _annotationOutbox.entries) {
      if (closed || offline || !kindleAnnotationsEnabled) break;
      final edit = object(entry.value);
      final id = text(edit['book']), edition = text(edit['edition']);
      try {
        final item = library.item(id);
        if (item['type'] != 'PDOC' || edition.isEmpty) {
          throw const KindleFailure('annotation_edition_unavailable');
        }
        Json? sidecar;
        var missing = false;
        try {
          sidecar = await library.client.sidecar(
            item,
            guid: edition,
            annotations: true,
          );
        } on KindleFailure catch (error) {
          if (error.status != 404) rethrow;
          missing = true;
        }
        if (closed || offline || !kindleAnnotationsEnabled) return;
        final current = object(_annotationOutbox[entry.key]);
        if (current.isEmpty || current['edition'] != edition) continue;
        final mark = KindleMark(
          text(current['type']),
          integer(current['start'], -1),
          end: current['end'] is int ? current['end'] as int : null,
          note: current['note'] as String?,
        );
        final erase = current['erase'] == true;
        if (!(erase ? mark.deletable : mark.valid)) {
          throw const KindleFailure('annotation_invalid');
        }
        final acrs = current['acrs'] as List? ?? [];
        // A 404 on the exact downloaded PDOC edition means there is no
        // sidecar yet. The first annotation can create it using its mapped ACR.
        final guid = missing ? edition : text(sidecar?['guid']);
        if (guid.isEmpty ||
            !(acrs.contains(guid) || acrs.contains(sidecar?['acr'])) ||
            sidecar != null && sidecar['annotations_available'] != true) {
          throw const KindleFailure('annotation_edition_unavailable');
        }
        final records = (sidecar?['records'] as List? ?? []).map(object);
        final matches = records.where(mark.sameRange);
        if (erase) {
          final requested = current['cloudId'];
          final candidate = matches
              .where(
                (record) =>
                    requested == null ||
                    'kindle:${record['annotationId']}' == requested,
              )
              .firstOrNull;
          if (candidate != null) {
            // If a previous response was lost, continue with readback only.
            if (current['submitted'] == true) continue;
            final modification = kindleTimestamp(
              candidate['lastModificationTime'] ?? candidate['creationTime'],
            );
            if (modification != null) {
              final delay = modification
                  .add(const Duration(milliseconds: 1100))
                  .difference(DateTime.now().toUtc());
              if (delay > Duration.zero &&
                  delay <= const Duration(seconds: 2)) {
                await Future<void>.delayed(delay);
                if (closed) return;
                if (offline ||
                    !kindleAnnotationsEnabled ||
                    object(_annotationOutbox[entry.key])['revision'] !=
                        current['revision']) {
                  continue;
                }
              }
            }
            final annotationId = text(candidate['annotationId']);
            if (annotationId.isEmpty) {
              throw const KindleFailure('annotation_edition_unavailable');
            }
            final id = 'kindle:$annotationId';
            // Amazon addresses a note by its ID and original body as well as
            // its range. Always take those fields from the matching sidecar.
            final deleteMark = mark.type == 'note'
                ? KindleMark(
                    mark.type,
                    mark.start,
                    end: mark.end,
                    note: kindleNoteText(candidate),
                  )
                : mark;
            if (mark.type == 'note' && !deleteMark.valid) {
              throw const KindleFailure('annotation_invalid');
            }
            _setAnnotationEdit(entry.key, {
              ...current,
              'cloudId': id,
              'submitted': true,
            });
            sidecar = await library.client.pushAnnotation(
              item,
              guid,
              deleteMark,
              erase: true,
              annotationId: mark.type == 'note' ? annotationId : null,
            );
          } else if (integer(current['settleAfter']) >
              DateTime.now().millisecondsSinceEpoch) {
            continue;
          }
        } else if (!records.any(mark.matches)) {
          if (current['submitted'] == true) continue;
          if (matches.isEmpty) {
            _setAnnotationEdit(entry.key, {...current, 'submitted': true});
            sidecar = await library.client.pushAnnotation(item, guid, mark);
          }
        }
        if (closed) return;
        final latest = object(_annotationOutbox[entry.key]);
        if (latest['revision'] == current['revision']) {
          if (erase) {
            _reconcileRemoval(id, entry.key, latest['cloudId'] as String?);
          }
          _setAnnotationEdit(entry.key, null);
        }
        final mapping = _mapping;
        if (_mappedBook == id && mapping != null && sidecar != null) {
          store.cache(profile.id, 'kindle:sidecar:$id', sidecar);
          _importAnnotations(id, mapping, sidecar);
        }
        if (conflicts.isEmpty && _outbox.isEmpty && _annotationOutbox.isEmpty) {
          syncFailure = null;
        }
      } on KindleFailure catch (error) {
        if (!closed) syncFailure = error.toString();
      } catch (_) {
        if (!closed) syncFailure = 'Kindle: annotation_sync_response';
      }
    }
    _annotationTimer?.cancel();
    if (!closed &&
        !offline &&
        kindleAnnotationsEnabled &&
        _annotationOutbox.isNotEmpty) {
      _annotationTimer = Timer(const Duration(minutes: 2), () {
        if (!closed && !offline) unawaited(sync());
      });
    }
  }

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
      super.pendingCount +
      (kindleSyncEnabled ? _outbox.length : 0) +
      (kindleAnnotationsEnabled ? _annotationOutbox.length : 0);
  @override
  void dispose() {
    _kindleTimer?.cancel();
    _annotationTimer?.cancel();
    super.dispose();
  }

  @override
  Future<Json?> externalDocumentPosition(Book book, File file) async {
    final generation = ++_mappingGeneration;
    _mappedBook = null;
    _mapping = null;
    _annotationsFetched = null;
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
        _importAnnotations(book.id, mapping, cachedSidecar);
        return chosen;
      }
      if (offline) {
        _importAnnotations(book.id, mapping, cachedSidecar);
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
  bool canApplyDocumentPosition(Book book, {bool force = false}) =>
      !closed &&
      !offline &&
      kindleSyncEnabled &&
      _mappedBook == book.id &&
      (force
          ? _syncWork == null
          : _canReplacePendingPosition(book.id) && !overlay(book).completed);

  bool _canReplacePendingPosition(String id) {
    final pending = _outbox[id];
    if (pending == null) return true;
    final revision = object(pending)['time'];
    return _syncWork == null &&
        revision != null &&
        conflicts[id]?['pending_time'] == revision;
  }

  @override
  Future<Json?> refreshDocumentPosition(Book book, {bool force = false}) async {
    final mapping = _mapping;
    if (mapping == null || !canApplyDocumentPosition(book, force: force)) {
      return null;
    }
    if (!force) {
      final chosen = _chosenKindlePosition(book.id, mapping);
      if (chosen != null) return chosen;
    }
    return _readDocumentPosition(
      book,
      mapping,
      _mappingGeneration,
      force: force,
    );
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
        prior['time'] == read['time'] &&
        prior['account'] == read['account']) {
      return;
    }
    store.cache(profile.id, key, {'edition': edition, 'read': read});
  }

  @override
  void externalDocumentPositionApplied(Book book, Json locator) {
    final mapping = _mapping;
    final force = locator['forcedCloud'] == true;
    if (mapping == null || !canApplyDocumentPosition(book, force: force)) {
      return;
    }
    final pending = _outbox;
    if (force &&
        object(pending[book.id])['time'] != locator['pendingRevision']) {
      return;
    }
    if (pending.remove(book.id) != null) {
      _saveOutbox(pending);
      conflicts.remove(book.id);
      if (conflicts.isEmpty) syncFailure = null;
    }
    _rememberCloudRead(book.id, mapping.primary, {
      'position': integer(locator['position']) + integer(locator['offset']),
      'time': locator['modified'],
      if (locator['account'] == true) 'account': true,
    });
  }

  @override
  void keepDocumentPosition(Book book, Json offer, int? position) {
    final mapping = _mapping;
    if (mapping == null || !canApplyDocumentPosition(book)) return;
    final id = book.id;
    final base = {
      'position': integer(offer['position']) + integer(offer['offset']),
      'time': offer['modified'],
      if (offer['account'] == true) 'account': true,
    };
    store.transaction(() {
      store.cache(profile.id, 'kindle:declined:$id', {
        'edition': mapping.primary,
        ...base,
      });
      _rememberCloudRead(id, mapping.primary, base);
      // Rebase this book's pending edit against the exact cloud record the
      // reader saw. A different, newer cloud edit can still win the next check.
      if (position != null && mapping.locator(position) != null) {
        _queueDocumentPosition(book, {'kindlePosition': position}, base: base);
      } else if (conflicts.remove(id) != null) {
        final pending = _outbox..remove(id);
        _saveOutbox(pending);
        if (conflicts.isEmpty) syncFailure = null;
      }
    });
    changed();
  }

  Future<Json?> _readDocumentPosition(
    Book book,
    KindlePositionMap mapping,
    int generation, {
    bool opening = false,
    bool force = false,
  }) async {
    final revision = force ? object(_outbox[book.id])['time'] : null;
    final item = library.item(book.id);
    final withAnnotations =
        kindleAnnotationsEnabled &&
        (opening ||
            force ||
            _annotationsFetched == null ||
            DateTime.now().difference(_annotationsFetched!) >=
                const Duration(minutes: 2));
    final (edition, account) = await (
      library.client
          .sidecar(item, guid: mapping.primary, annotations: withAnnotations)
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
    if (sidecar != null && withAnnotations) {
      _annotationsFetched = DateTime.now();
      _importAnnotations(book.id, mapping, sidecar);
    }
    if (opening && sidecar != null) {
      store.cache(profile.id, 'kindle:sidecar:${book.id}', sidecar);
    }
    final remote = kindleLastRead(sidecar, account: accountMatch);
    if (remote == null ||
        !canApplyDocumentPosition(book, force: force) ||
        force && revision != object(_outbox[book.id])['time']) {
      return null;
    }
    final locator = mapping.locator(integer(remote['position']));
    if (locator == null) return null;
    final changedPosition = remote['position'] != baseline?['position'];
    final offer = {
      ...locator,
      'modified': remote['time'],
      if (remote['updated'] != null &&
          (!changedPosition || remote['updated'] != baseline?['time']))
        'displayModified': remote['updated'],
      if (remote['account'] == true) 'account': true,
      if (force) ...{'forcedCloud': true, 'pendingRevision': revision},
    };
    if (force) return offer;
    final declined = object(
      store.cached(profile.id, 'kindle:declined:${book.id}'),
    );
    if (declined['edition'] == mapping.primary &&
        declined['position'] == remote['position'] &&
        declined['time'] == remote['time']) {
      return null;
    }
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
    if (remoteTime == previousTime &&
        changedPosition &&
        baseline?['account'] == true &&
        remote['account'] != true) {
      return null;
    }
    // Once a matching cloud record has been seen, its changes can be compared
    // in Amazon's clock domain. Local EPUB saves include millisecond precision
    // and may come from a device whose clock is ahead of Amazon.
    final cloudMoved =
        baseline != null &&
        (changedPosition ||
            remoteTime != null &&
                (previousTime == null || remoteTime.isAfter(previousTime)));
    if (localTime != null &&
        (remoteTime == null || !remoteTime.isAfter(localTime)) &&
        !cloudMoved) {
      _rememberCloudRead(book.id, mapping.primary, remote);
      return null;
    }
    return offer;
  }

  @override
  void documentPosition(Book book, Json event) =>
      _queueDocumentPosition(book, event);

  void _queueDocumentPosition(Book book, Json event, {Json? base}) {
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
    if (existing['position'] == position && base == null) return;
    final remote =
        base ??
        _cloudReadBaseline(book.id, _mapping!) ??
        kindleLastRead(sidecar);
    pending[book.id] = {
      'position': position,
      'time': DateTime.now().toUtc().toIso8601String(),
      'acr': text(sidecar['acr']),
      'acrs': _mapping!.acrs.toList(),
      'guid': text(sidecar['guid']),
      'target_guid': _mapping!.primary,
      'base_position': existing.isEmpty || base != null
          ? (remote?['position'])
          : existing['base_position'],
      'base_time': existing.isEmpty || base != null
          ? (remote?['time'])
          : existing['base_time'],
      'not_before':
          DateTime.now().millisecondsSinceEpoch + (base == null ? 3000 : 0),
    };
    _saveOutbox(pending);
    if (conflicts.remove(book.id) != null && conflicts.isEmpty) {
      syncFailure = null;
    }
    _kindleTimer?.cancel();
    _kindleTimer = Timer(Duration(seconds: base == null ? 3 : 0), () {
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
                        : null);
            if (!force &&
                remote != null &&
                remote['position'] != local['position'] &&
                remote['position'] != local['base_position'] &&
                (remoteTime == null ||
                    comparisonTime == null ||
                    !remoteTime.isBefore(comparisonTime))) {
              conflicts[entry.key] = {...remote, 'pending_time': local['time']};
              syncFailure = null;
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
      if (target == null) await _syncAnnotations();
      if (!closed) changed();
    } finally {
      if (!closed && !offline && kindleSyncEnabled) {
        _schedulePositionRetry();
      }
    }
  }

  void _schedulePositionRetry() {
    _kindleTimer?.cancel();
    final due = [
      for (final entry in _outbox.entries)
        if (conflicts[entry.key]?['pending_time'] !=
            object(entry.value)['time'])
          integer(object(entry.value)['not_before']),
    ];
    if (due.isEmpty) return;
    final delay =
        due.reduce((a, b) => a < b ? a : b) -
        DateTime.now().millisecondsSinceEpoch;
    _kindleTimer = Timer(
      Duration(milliseconds: delay > 0 ? delay.clamp(100, 30000) : 30000),
      () {
        if (!closed && !offline) unawaited(sync());
      },
    );
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
