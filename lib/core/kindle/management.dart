import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import 'client.dart';
import 'import.dart';
import 'edition_migration.dart';
import 'positions.dart';
import 'repository.dart';

/// Remote mutations of personal documents only. HTTP success alone never
/// establishes deletion or state migration. Journal entries survive app restarts.
class KindleDocumentManager {
  KindleDocumentManager(this.repository);
  final KindleRepository repository;
  KindleClient get client => repository.library.client;
  static final _starting = Expando<bool>();
  static const _journal = 'kindle:management';
  List<Json> get operations =>
      (repository.store.cached(repository.profile.id, _journal) as List? ?? [])
          .map(object)
          .toList();
  void _check() {
    if (repository.closed || repository.offline || client.session == null) {
      throw const KindleFailure('management_offline');
    }
  }

  void _save(Json operation) {
    _check();
    repository.store.cache(repository.profile.id, _journal, [
      ...operations.where(
        (entry) => entry['operation'] != operation['operation'],
      ),
      {...operation, 'updated': DateTime.now().toUtc().toIso8601String()},
    ]);
  }

  Json _personal(Book book) {
    _check();
    final item = repository.library.item(book.id);
    if (item['type'] != 'PDOC') {
      throw const KindleFailure('management_personal_only');
    }
    if (repository.downloading.containsKey(book.id) ||
        object(
              repository.store.cached(repository.profile.id, 'kindle:outbox'),
            )[book.id] !=
            null) {
      throw const KindleFailure('management_busy');
    }
    return item;
  }

  /// Retrieve this personal document through the app's normal verified queue.
  /// The display name carries its prepared format without renaming the cache.
  Future<XFile> sourceForEdit(Book book) async {
    _personal(book);
    var prepared = await repository.book(book.id);
    if (repository.store.download(repository.profile.id, book.id)?['status'] !=
            'ready' ||
        !await repository.bookFile(prepared).exists()) {
      await repository.download(book);
      _personal(book);
      prepared = await repository.book(book.id);
    }
    if (!const {'epub', 'pdf'}.contains(prepared.format)) {
      throw const KindleFailure('management_source');
    }
    final file = repository.bookFile(prepared);
    if (!await file.exists()) throw const KindleFailure('management_source');
    return _KindleEditSource(file.path, '${book.title}.${prepared.format}');
  }

  Future<Json> _backup(Book book, String kind) async {
    if (_starting[repository] == true) {
      throw const KindleFailure('management_busy');
    }
    _starting[repository] = true;
    try {
      return await _createBackup(book, kind);
    } finally {
      _starting[repository] = false;
    }
  }

  Future<Json> _createBackup(Book book, String kind) async {
    final item = _personal(book);
    if (operations.any(
      (op) =>
          op['book'] == book.id &&
          !const ['done', 'rejected'].contains(op['state']),
    )) {
      throw const KindleFailure('management_pending');
    }
    final originalFile = repository.bookFile(await repository.book(book.id));
    final sourceMap = await originalFile.exists()
        ? await KindlePositionMap.open(originalFile.path)
        : null;
    final sourceGuid = sourceMap?.primary;
    final sidecar = await client.sidecar(
      item,
      guid: sourceGuid,
      annotations: true,
    );
    _check();
    if (operations.any(
      (op) =>
          op['book'] == book.id &&
          !const ['done', 'rejected'].contains(op['state']),
    )) {
      throw const KindleFailure('management_pending');
    }
    // A missing/malformed sidecar is not an empty set of bookmarks.
    if (sidecar == null ||
        sidecar['annotations_loaded'] != true ||
        sidecar['annotations_complete'] != true) {
      throw const KindleFailure('management_backup_unavailable');
    }
    final backup = <String, dynamic>{
      'operation': kindleRandom(18),
      'kind': kind,
      'state': 'backed_up',
      'book': book.id,
      'item': item,
      'sidecar': sidecar,
      'source_guid': sourceGuid,
      'progress': repository.store.progress(repository.profile.id, book.id),
      'epub': repository.store.cached(repository.profile.id, 'epub:${book.id}'),
      'bookmarks':
          repository.store.cached(
            repository.profile.id,
            'epubBookmarks:${book.id}',
          ) ??
          [],
      'annotations':
          repository.store.cached(
            repository.profile.id,
            'kindle:annotations:${book.id}',
          ) ??
          [],
      'created': DateTime.now().toUtc().toIso8601String(),
    };
    final folder = Directory(
      p.join(
        repository.directory.path,
        repository.profile.id,
        'kindle-management',
      ),
    );
    await folder.create(recursive: true);
    _check();
    if (kind == 'replace') {
      final source = repository.bookFile(await repository.book(book.id));
      if (await source.exists()) {
        final copy = File(p.join(folder.path, '${backup['operation']}.source'));
        await source.copy(copy.path);
        backup['source'] = p.basename(copy.path);
        backup['source_sha256'] = (await sha256.bind(copy.openRead()).first)
            .toString();
      }
    }
    final encoded = await _encodeBackup(backup);
    final file = File(p.join(folder.path, '${backup['operation']}.json'));
    final partial = File('${file.path}.part');
    await partial.writeAsString(encoded, flush: true);
    await partial.rename(file.path);
    final operation = <String, dynamic>{
      for (final key in [
        'operation',
        'kind',
        'state',
        'book',
        'item',
        'created',
      ])
        key: backup[key],
      'backup': p.basename(file.path),
    };
    _save(operation);
    return operation;
  }

  Future<List<int>> _request(
    http.Request request, {
    int limit = 4 * 1024 * 1024,
    void Function(Map<String, String>)? onHeaders,
  }) async {
    _check();
    request.followRedirects = false;
    try {
      final reply = await client
          .importRequest(request)
          .timeout(const Duration(seconds: 60));
      onHeaders?.call(reply.headers);
      final bytes = <int>[];
      await for (final chunk in reply.stream.timeout(
        const Duration(seconds: 60),
      )) {
        if (bytes.length + chunk.length > limit) {
          throw const KindleFailure('management_response_size');
        }
        bytes.addAll(chunk);
      }
      _check();
      if (reply.statusCode < 200 || reply.statusCode >= 300) {
        throw KindleFailure('management_request', status: reply.statusCode);
      }
      return bytes;
    } on KindleFailure {
      rethrow;
    } catch (_) {
      throw const KindleFailure('management_network');
    }
  }

  Future<(String, String)> _webAuthorization() async {
    // Mint website cookies from THIS account's refresh token; never borrow a
    // browser profile or accept pasted cookies from an unrelated account.
    final exchange =
        http.Request(
            'POST',
            Uri.https('www.amazon.it', '/ap/exchangetoken/cookies'),
          )
          ..bodyFields = {
            'app_name': 'Kindle for iOS',
            'app_version': kindleAppVersion,
            'source_token': text(client.session!.json['refresh_token']),
            'source_token_type': 'refresh_token',
            'requested_token_type': 'auth_cookies',
            'domain': '.amazon.it',
          };
    final raw = object(
      object(object(_decode(await _request(exchange)))['response'])['tokens'],
    )['cookies'];
    final cookies = <String, String>{};
    for (final entry in object(raw).entries) {
      if (!const {
        '.amazon.it',
        'amazon.it',
        '.www.amazon.it',
        'www.amazon.it',
      }.contains(entry.key)) {
        continue;
      }
      for (final cookie in (entry.value as List? ?? []).map(object)) {
        final name = text(cookie['Name']);
        // The exchange endpoint wraps cookie values in literal quotes. Match
        // Amazon clients' cookie normalization before constructing a header.
        final value = text(cookie['Value']).replaceAll('"', '');
        if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name) &&
            !RegExp(r'[;\r\n\x00]').hasMatch(value)) {
          cookies[name] = value;
        }
      }
    }
    if (cookies.isEmpty) throw const KindleFailure('management_authorization');
    String header() =>
        cookies.entries.map((c) => '${c.key}=${c.value}').join('; ');
    final page = http.Request('GET', Uri.https('www.amazon.it', '/hz/mycd/myx'))
      ..headers.addAll({'Cookie': header(), 'User-Agent': 'Mozilla/5.0'});
    final html = utf8.decode(
      await _request(
        page,
        onHeaders: (headers) {
          // The retail page can rotate the session which issued the CSRF token.
          for (final value in (headers['set-cookie'] ?? '').split(
            RegExp(r',(?=\s*[A-Za-z0-9_-]+=)'),
          )) {
            if (value.trim().isEmpty) continue;
            try {
              final cookie = Cookie.fromSetCookieValue(value.trim());
              final domain = cookie.domain?.replaceFirst(RegExp(r'^\.'), '');
              if (domain != null &&
                  domain != 'amazon.it' &&
                  domain != 'www.amazon.it') {
                continue;
              }
              if (cookie.path != null &&
                  !'/hz/mycd/ajax'.startsWith(cookie.path!)) {
                continue;
              }
              if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(cookie.name) ||
                  RegExp(r'[;\r\n\x00]').hasMatch(cookie.value)) {
                continue;
              }
              if (cookie.maxAge == 0 ||
                  cookie.expires?.isBefore(DateTime.now()) == true) {
                cookies.remove(cookie.name);
              } else {
                cookies[cookie.name] = cookie.value.replaceAll('"', '');
              }
            } on HttpException {
              /* Ignore malformed cookies, never forward them. */
            } on FormatException {
              /* Ignore malformed cookies, never forward them. */
            }
          }
        },
      ),
    );
    final declaredCsrf = RegExp(
      r'''var\s+csrfToken\s*=\s*["']([^"'\r\n]+)["']''',
    ).firstMatch(html)?.group(1);
    final csrf =
        declaredCsrf ??
        RegExp(r'''(?:var\s+)?csrfToken["']?\s*[=:]\s*["']([^"'\r\n]+)["']''')
            .firstMatch(html)
            ?.group(1);
    if (csrf == null || csrf.isEmpty) {
      throw const KindleFailure('management_authorization');
    }
    return (header(), csrf);
  }

  /// Check this account's web authorization without mutating any document.
  Future<void> checkAuthorization() async {
    _check();
    await _webAuthorization();
  }

  Future<void> delete(Book book) async {
    final operation = await _backup(book, 'delete');
    try {
      final auth = await _webAuthorization();
      final item = _personal(book);
      await _submitDeletion(operation, item, auth);
    } catch (_) {
      if (operation['state'] == 'backed_up') {
        operation['state'] = 'rejected';
        _save(operation);
      }
      rethrow;
    }
  }

  Future<void> _submitDeletion(
    Json operation,
    Json item,
    (String, String) auth,
  ) async {
    final replacement = operation['kind'] == 'replace';
    // Current MyCD ajax_fmyx protocol, scoped to one PDOC. No EBOK operation,
    // bulk deletion, fallback endpoint or automatic replay is permitted.
    final request =
        http.Request('POST', Uri.https('www.amazon.it', '/hz/mycd/ajax'))
          ..headers.addAll({
            'Cookie': auth.$1,
            'client': 'MYX',
            'Origin': 'https://www.amazon.it',
            'Referer': 'https://www.amazon.it/hz/mycd/myx',
            'User-Agent': 'Mozilla/5.0',
          })
          ..bodyFields = {
            'csrfToken': auth.$2,
            'data': jsonEncode({
              'param': {
                'DeleteContent': {
                  'asinDetails': {
                    text(item['id']): {'category': 'KindlePDoc'},
                  },
                },
              },
            }),
          };
    operation['state'] = replacement
        ? 'replacement_retiring'
        : 'delete_submitting';
    _save(operation); // durable BEFORE the irreversible network write
    try {
      await _request(request);
    } catch (_) {
      operation['state'] = replacement
          ? 'replacement_retirement_uncertain'
          : 'delete_uncertain';
      _save(operation);
      rethrow;
    }
    operation['state'] = replacement
        ? 'replacement_retirement_verifying'
        : 'delete_verifying';
    _save(operation);
    await verifyDeletion(text(operation['operation']));
  }

  /// Retire the previous edition only after remote readback and local atomic
  /// restoration. No interrupted or unverified migration can enter this path.
  Future<void> retireReplacement(String id) async {
    _check();
    if (_starting[repository] == true) {
      throw const KindleFailure('management_busy');
    }
    _starting[repository] = true;
    try {
      final operation = operations
          .where(
            (op) =>
                op['operation'] == id &&
                op['kind'] == 'replace' &&
                op['state'] == 'progress_restored',
          )
          .firstOrNull;
      if (operation == null) throw const KindleFailure('management_operation');
      final plan = object(operation['migration_plan']);
      final original = await repository.book(text(operation['book']));
      final item = _personal(original);
      final updated = await repository.book(text(plan['target']));
      final target = _personal(updated);
      if (!await client.readingStateConfirmed(
        target,
        text(plan['guid']),
        position: plan['position'] as int?,
        bookmarks: (plan['bookmarks'] as List).cast<int>(),
      )) {
        throw const KindleFailure('management_migration_not_confirmed');
      }
      final auth = await _webAuthorization();
      final folder = p.join(
        repository.directory.path,
        repository.profile.id,
        'kindle-management',
      );
      final backup = object(
        jsonDecode(
          await File(p.join(folder, text(operation['backup']))).readAsString(),
        ),
      );
      final current = await client.sidecar(
        item,
        guid: text(backup['source_guid']).isEmpty
            ? null
            : text(backup['source_guid']),
        annotations: true,
      );
      if (current == null ||
          _readingSnapshot(current) !=
              _readingSnapshot(object(backup['sidecar']))) {
        throw const KindleFailure('management_source_changed');
      }
      _personal(original);
      _personal(updated);
      await _submitDeletion(operation, item, auth);
    } finally {
      _starting[repository] = false;
    }
  }

  void abandonBeforeSubmission(String id) {
    final operation = operations
        .where((op) => op['operation'] == id)
        .firstOrNull;
    if (operation == null || operation['state'] != 'backed_up') {
      throw const KindleFailure('management_pending');
    }
    operation['state'] = 'rejected';
    _save(operation);
  }

  Future<bool> verifyDeletion(String id) async {
    _check();
    final operation = operations
        .where(
          (op) =>
              op['operation'] == id &&
              (op['kind'] == 'delete' ||
                  op['kind'] == 'replace' &&
                      const {
                        'replacement_retiring',
                        'replacement_retirement_uncertain',
                        'replacement_retirement_verifying',
                        'done',
                      }.contains(op['state'])),
        )
        .firstOrNull;
    if (operation == null) throw const KindleFailure('management_operation');
    final item = object(operation['item']);
    final catalog = await client.catalog(full: true);
    if (catalog['complete'] != true) {
      throw const KindleFailure('management_catalog_incomplete');
    }
    final absent = !(catalog['items'] as List)
        .map(object)
        .any((entry) => entry['id'] == item['id'] && entry['type'] == 'PDOC');
    operation['state'] = absent
        ? 'done'
        : operation['kind'] == 'replace'
        ? 'replacement_retirement_verifying'
        : 'delete_verifying';
    _save(operation);
    if (absent) {
      // Reconcile the visible catalog, retaining source files, backup and progress.
      await repository.library.refresh(full: true);
      repository.localCatalogChanged();
    }
    return absent;
  }

  /// Resume a previously accepted update without uploading it again. The plan
  /// is journalled before any cloud write, and an interrupted write is only read
  /// back. The original cannot be retired while this operation is incomplete.
  Future<void> restoreReplacement(String id) async {
    _check();
    if (_starting[repository] == true) {
      throw const KindleFailure('management_busy');
    }
    _starting[repository] = true;
    try {
      final operation = operations
          .where((op) => op['operation'] == id && op['kind'] == 'replace')
          .firstOrNull;
      if (operation == null ||
          !const {
            'replacement_migration_required',
            'migration_submitting',
            'migration_uncertain',
            'progress_restored',
          }.contains(operation['state'])) {
        throw const KindleFailure('management_operation');
      }
      if (operation['state'] == 'progress_restored') return;
      final folder = Directory(
        p.join(
          repository.directory.path,
          repository.profile.id,
          'kindle-management',
        ),
      );
      final backupName = text(operation['backup']);
      if (p.basename(backupName) != backupName) {
        throw const KindleFailure('management_backup_unavailable');
      }
      final backup = object(
        jsonDecode(await File(p.join(folder.path, backupName)).readAsString()),
      );
      final sourceName = text(backup['source']);
      if (sourceName.isEmpty || p.basename(sourceName) != sourceName) {
        throw const KindleFailure('management_source');
      }
      final source = File(p.join(folder.path, sourceName));
      if ((await sha256.bind(source.openRead()).first).toString() !=
          backup['source_sha256']) {
        throw const KindleFailure('management_source');
      }
      await repository.library.refresh(full: true);
      _check();
      final original = await repository.book(text(operation['book']));
      final originalItem = _personal(original);
      final targetItem = repository.library.items
          .where(
            (item) =>
                item['id'] == operation['new_id'] && item['type'] == 'PDOC',
          )
          .firstOrNull;
      if (targetItem == null || targetItem['id'] == originalItem['id']) {
        throw const KindleFailure('management_conversion_pending');
      }
      var updated = await repository.book(repository.library.idFor(targetItem));
      _personal(updated);
      if (repository.store.download(
                repository.profile.id,
                updated.id,
              )?['status'] !=
              'ready' ||
          !await repository.bookFile(updated).exists()) {
        await repository.download(updated);
      }
      updated = await repository.book(updated.id);
      final mapping = await KindleEditionMigration.open(
        source.path,
        repository.bookFile(updated).path,
      );
      // Older journals queried CDE without the delivered edition GUID. Retain
      // that snapshot, then bind an updated one to the verified source. Never
      // change a plan after a state write might have started.
      if (text(backup['source_guid']).isEmpty) {
        if (operation['state'] != 'replacement_migration_required') {
          throw const KindleFailure('management_source_changed');
        }
        final verified = await client.sidecar(
          originalItem,
          guid: mapping.oldMap.primary,
          annotations: true,
        );
        if (verified == null ||
            verified['annotations_complete'] != true ||
            !mapping.oldMap.matches(verified)) {
          throw const KindleFailure('management_backup_unavailable');
        }
        final oldRecords = (object(backup['sidecar'])['records'] as List? ?? [])
            .map(object);
        final currentRecords = (verified['records'] as List? ?? [])
            .map(object)
            .toList();
        for (final record in oldRecords.where(
          (r) => const {
            'kindle.bookmark',
            'kindle.note',
            'kindle.highlight',
          }.contains(r['type']),
        )) {
          if (!currentRecords.any(
            (r) =>
                r['annotationId'] == record['annotationId'] &&
                r['type'] == record['type'] &&
                r['startPosition'] == record['startPosition'],
          )) {
            throw const KindleFailure('management_source_changed');
          }
        }
        final oldRead = kindleLastRead(object(backup['sidecar']));
        final newRead = kindleLastRead(verified);
        final oldTime = DateTime.tryParse(text(oldRead?['time']));
        final newTime = DateTime.tryParse(text(newRead?['time']));
        if (oldRead != null &&
            oldRead['position'] != newRead?['position'] &&
            (newRead == null ||
                oldTime != null &&
                    (newTime == null || oldTime.isAfter(newTime)))) {
          throw const KindleFailure('management_source_changed');
        }
        backup['sidecar'] = verified;
        backup['source_guid'] = mapping.oldMap.primary;
        final name = '${operation['operation']}-edition.json';
        final partial = File(p.join(folder.path, '$name.part'));
        await partial.writeAsString(await _encodeBackup(backup), flush: true);
        await partial.rename(p.join(folder.path, name));
        operation['previous_backup'] = operation['backup'];
        operation['backup'] = name;
        _save(operation);
      }
      var plan = object(operation['migration_plan']);
      final interrupted =
          operation['state'] != 'replacement_migration_required';
      if (!interrupted) {
        final saved = object(backup['sidecar']);
        final current = await client.sidecar(
          originalItem,
          guid: text(backup['source_guid']),
          annotations: true,
        );
        if (current == null ||
            !mapping.oldMap.matches(current) ||
            _readingSnapshot(current) != _readingSnapshot(saved)) {
          throw const KindleFailure('management_source_changed');
        }
        final records = (saved['records'] as List? ?? []).map(object).toList();
        if (records.any(
          (r) => const {'kindle.note', 'kindle.highlight'}.contains(r['type']),
        )) {
          throw const KindleFailure('management_annotation_migration');
        }
        Json? targetState;
        try {
          targetState = await client.sidecar(
            targetItem,
            guid: mapping.newMap.primary,
            annotations: true,
          );
        } on KindleFailure catch (error) {
          if (error.status != 404) rethrow;
        }
        if (targetState != null &&
            (targetState['annotations_complete'] != true ||
                ((kindleLastRead(targetState)?['position'] as int? ?? 0) != 0 ||
                    (targetState['records'] as List? ?? [])
                        .map(object)
                        .any(
                          (r) => const {
                            'kindle.bookmark',
                            'kindle.note',
                            'kindle.highlight',
                          }.contains(r['type']),
                        )))) {
          throw const KindleFailure('management_target_changed');
        }
        final localMarks = mapping.bookmarks(
          (backup['bookmarks'] as List? ?? []).map(object).toList(),
        );
        final epub = object(backup['epub']);
        final remote = kindleLastRead(saved);
        int? oldPosition = remote?['position'] as int?;
        final localTime = DateTime.tryParse(text(epub['modified']));
        final remoteTime = DateTime.tryParse(text(remote?['time']));
        if (text(epub['cfi']).isNotEmpty &&
            (oldPosition == null ||
                localTime != null &&
                    (remoteTime == null || localTime.isAfter(remoteTime)))) {
          oldPosition = mapping.cfiPosition(text(epub['cfi']));
        }
        final bookmarks = records
            .where((r) => r['type'] == 'kindle.bookmark')
            .map((r) => mapping.position(int.parse('${r['startPosition']}')))
            .toSet()
            .toList();
        plan = {
          'guid': mapping.newMap.primary,
          'position': oldPosition == null
              ? null
              : mapping.position(oldPosition),
          'locator': oldPosition == null ? null : mapping.locator(oldPosition),
          'bookmarks': bookmarks,
          'local_bookmarks': localMarks,
          'target': updated.id,
        };
        operation['migration_plan'] = plan;
        operation['state'] = 'migration_submitting';
        _save(operation);
        try {
          await client.pushReadingState(
            targetItem,
            text(plan['guid']),
            position: plan['position'] as int?,
            bookmarks: bookmarks,
          );
        } catch (_) {
          operation['state'] = 'migration_uncertain';
          _save(operation);
          rethrow;
        }
      }
      if (plan['target'] != updated.id ||
          plan['guid'] != mapping.newMap.primary ||
          !await client.readingStateConfirmed(
            targetItem,
            text(plan['guid']),
            position: plan['position'] as int?,
            bookmarks: (plan['bookmarks'] as List).cast<int>(),
          )) {
        operation['state'] = 'migration_uncertain';
        _save(operation);
        throw const KindleFailure('management_migration_not_confirmed');
      }
      _personal(original);
      _personal(updated);
      final currentSource = await client.sidecar(
        originalItem,
        guid: text(backup['source_guid']),
        annotations: true,
      );
      if (currentSource == null ||
          _readingSnapshot(currentSource) !=
              _readingSnapshot(object(backup['sidecar']))) {
        throw const KindleFailure('management_source_changed');
      }
      _check();
      final progress = object(backup['progress']);
      final epub = object(backup['epub']);
      final locator = object(plan['locator']);
      repository.store.transaction(() {
        // Preserve completion/read dates, and replace the edition-specific
        // locator. Old progress and its backup remain available for recovery.
        if (progress.isNotEmpty) {
          final progression = object(progress['progression']);
          repository.store.recordProgress(repository.profile.id, updated.id, {
            ...progress,
            if (progress['completed'] == true) 'page': updated.pages,
            if (locator.isNotEmpty)
              'progression': {
                ...progression,
                'locator': {
                  'href': locator['href'],
                  'type': 'application/xhtml+xml',
                  'locations': {
                    ...object(object(progression['locator'])['locations']),
                    'fragments': <String>[],
                  },
                },
              },
          });
        }
        repository.store.cache(repository.profile.id, 'epub:${updated.id}', {
          ...epub,
          'cfi': '',
          'chapter': 0,
          'progress': 0,
          if (locator.isNotEmpty) 'kindleResume': locator,
        });
        repository.store.cache(
          repository.profile.id,
          'epubBookmarks:${updated.id}',
          plan['local_bookmarks'],
        );
        repository.store.cache(
          repository.profile.id,
          'kindle:replacement:${original.id}',
          {'book': updated.id, 'operation': id},
        );
        operation['state'] = 'progress_restored';
        _save(operation);
      });
      repository.localCatalogChanged();
    } finally {
      _starting[repository] = false;
    }
  }

  /// Stage an updated version with an exact identity returned by Amazon. Until
  /// cloud bookmarks can be written and read back, retirement is prohibited.
  Future<String> sendUpdatedVersion(
    Book book,
    XFile prepared, {
    required String title,
    required String author,
    List<String> targets = const [],
    required KindleImportCancellation cancel,
    void Function(int, int)? onProgress,
    void Function()? onSubmitting,
  }) async {
    if (title.trim().isEmpty || title.length > 250 || author.length > 250) {
      throw const KindleFailure('import_metadata');
    }
    cancel.check();
    final operation = await _backup(book, 'replace');
    try {
      // Bind the exact prepared file before the upload, retaining no file bytes.
      operation['sha256'] = (await sha256.bind(prepared.openRead()).first)
          .toString();
      operation['title'] = title;
      operation['state'] = 'replacement_submitting';
      _save(operation);
      final sku = await KindleImporter(client).upload(
        prepared,
        title: title,
        author: author,
        targets: const [],
        archive: true,
        cancel: cancel,
        onProgress: onProgress,
        onSubmitting: onSubmitting,
      );
      operation['new_id'] = sku;
      operation['state'] = 'replacement_migration_required';
      _save(operation);
      return sku;
    } catch (error) {
      operation['state'] =
          operation['state'] == 'backed_up' ||
              error is KindleFailure &&
                  error.code != 'import_delivery_uncertain'
          ? 'rejected'
          : 'replacement_uncertain';
      _save(operation);
      rethrow;
    }
  }
}

class _KindleEditSource extends XFile {
  _KindleEditSource(super.path, this._name);
  final String _name;
  @override
  String get name => _name;
}

Json _decode(List<int> bytes) {
  try {
    return object(jsonDecode(utf8.decode(bytes)));
  } catch (_) {
    throw const KindleFailure('management_response');
  }
}

String _readingSnapshot(Json sidecar) {
  dynamic ordered(dynamic value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: ordered(value[key])};
    }
    if (value is List) return value.map(ordered).toList();
    return value;
  }

  final records =
      (sidecar['records'] as List? ?? [])
          .map((r) => jsonEncode(ordered(r)))
          .toList()
        ..sort();
  return jsonEncode({
    'guid': sidecar['guid'],
    'acr': sidecar['acr'],
    'annotations_complete': sidecar['annotations_complete'],
    'records': records,
  });
}

Future<String> _encodeBackup(Json value) =>
    Isolate.run(() => jsonEncode(value));
