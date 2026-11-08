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
    final sidecar = await client.sidecar(item, annotations: true);
    _check();
    if (operations.any(
      (op) =>
          op['book'] == book.id &&
          !const ['done', 'rejected'].contains(op['state']),
    )) {
      throw const KindleFailure('management_pending');
    }
    // A missing/malformed sidecar is not an empty set of bookmarks.
    if (sidecar == null || sidecar['annotations_loaded'] != true) {
      throw const KindleFailure('management_backup_unavailable');
    }
    final backup = <String, dynamic>{
      'operation': kindleRandom(18),
      'kind': kind,
      'state': 'backed_up',
      'book': book.id,
      'item': item,
      'sidecar': sidecar,
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
    final encoded = await Isolate.run(() => jsonEncode(backup));
    final folder = Directory(
      p.join(
        repository.directory.path,
        repository.profile.id,
        'kindle-management',
      ),
    );
    await folder.create(recursive: true);
    _check();
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
  }) async {
    _check();
    request.followRedirects = false;
    try {
      final reply = await client
          .importRequest(request)
          .timeout(const Duration(seconds: 60));
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
        final name = text(cookie['Name']), value = text(cookie['Value']);
        if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name) &&
            !RegExp(r'[;\r\n\x00]').hasMatch(value)) {
          cookies[name] = value;
        }
      }
    }
    if (cookies.isEmpty) throw const KindleFailure('management_authorization');
    final header = cookies.entries.map((c) => '${c.key}=${c.value}').join('; ');
    final page = http.Request('GET', Uri.https('www.amazon.it', '/hz/mycd/myx'))
      ..headers.addAll({'Cookie': header, 'User-Agent': 'Mozilla/5.0'});
    final html = utf8.decode(await _request(page));
    final csrf = RegExp(
      r'''(?:var\s+)?csrfToken["']?\s*[=:]\s*["']([^"'\r\n]+)["']''',
    ).firstMatch(html)?.group(1);
    if (csrf == null || csrf.isEmpty) {
      throw const KindleFailure('management_authorization');
    }
    return (header, csrf);
  }

  Future<void> delete(Book book) async {
    final operation = await _backup(book, 'delete');
    try {
      final auth = await _webAuthorization();
      final item = _personal(book);
      // Recorded consumer-web protocol, scoped to one PDOC. No EBOK operation,
      // bulk deletion, fallback endpoint or automatic replay is permitted.
      final request =
          http.Request(
              'POST',
              Uri.https(
                'www.amazon.it',
                '/mn/dcw/myx/ajax-activity/ref=myx_ajax',
              ),
            )
            ..headers.addAll({
              'Cookie': auth.$1,
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
      operation['state'] = 'delete_submitting';
      _save(operation); // durable BEFORE the irreversible network write
      try {
        await _request(request);
      } catch (_) {
        operation['state'] = 'delete_uncertain';
        _save(operation);
        rethrow;
      }
      operation['state'] = 'delete_verifying';
      _save(operation);
      await verifyDeletion(text(operation['operation']));
    } catch (_) {
      if (operation['state'] == 'backed_up') {
        operation['state'] = 'rejected';
        _save(operation);
      }
      rethrow;
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
        .where((op) => op['operation'] == id && op['kind'] == 'delete')
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
    operation['state'] = absent ? 'done' : 'delete_verifying';
    _save(operation);
    if (absent) {
      // Reconcile the visible catalog, retaining source files, backup and progress.
      await repository.library.refresh(full: true);
      repository.localCatalogChanged();
    }
    return absent;
  }

  /// Stage an updated version with an exact identity returned by Amazon. Until
  /// cloud bookmarks can be written and read back, retirement is prohibited.
  Future<String> sendUpdatedVersion(
    Book book,
    XFile prepared, {
    required String title,
    required String author,
    required List<String> targets,
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
        targets: targets,
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

Json _decode(List<int> bytes) {
  try {
    return object(jsonDecode(utf8.decode(bytes)));
  } catch (_) {
    throw const KindleFailure('management_response');
  }
}
