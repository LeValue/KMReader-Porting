import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'models.dart';
import 'store.dart';

class DocumentLease {
  DocumentLease(this.file, this._release);
  final File file;
  void Function()? _release;
  void close() {
    _release?.call();
    _release = null;
  }
}

/// Versioned originals keep a running PDF/EPUB on an immutable file while a
/// conditional HEAD refresh prepares the next opening. Downloads stay pinned
/// separately, outside this disposable cache.
class DocumentCache {
  DocumentCache({
    required this.directory,
    required this.server,
    required this.store,
    required this.api,
  });
  final Directory directory;
  final String server;
  final LocalStore store;
  final KomgaApi api;
  final _owner =
      'document-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  final _loads = <String, Future<File>>{};
  final _refreshes = <String, Future<void>>{};
  final _active = <String, int>{};
  Timer? _trimTimer;
  bool _closed = false;
  int get budget =>
      (store.setting<int>('documentCacheMb') ?? 1024).clamp(128, 8192) *
      1024 *
      1024;
  String _key(Book book) => 'documentCache:${book.id}';
  String _fingerprint(Book book) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            book.json['fileHash'],
            book.json['sizeBytes'],
            book.json['lastModified'],
            book.media['lastModified'],
          ]),
        ),
      )
      .toString();
  File? _file(Json entry) {
    final name = text(entry['file']);
    if (!RegExp(r'^[a-f0-9]{64}-[0-9]+\.(pdf|epub)$').hasMatch(name)) {
      return null;
    }
    return File(p.join(directory.path, name));
  }

  DocumentLease _lease(File file) {
    _active.update(file.path, (v) => v + 1, ifAbsent: () => 1);
    return DocumentLease(file, () {
      final remaining = (_active[file.path] ?? 1) - 1;
      if (remaining <= 0) {
        _active.remove(file.path);
      } else {
        _active[file.path] = remaining;
      }
      scheduleTrim();
    });
  }

  Future<DocumentLease> open(
    Book book, {
    required File pinned,
    required bool offline,
  }) async {
    if (_closed) throw StateError('Document cache closed');
    if (await pinned.exists()) {
      final file = await _adoptLegacy(book, pinned);
      final lease = _lease(file);
      if (!offline && file.path != pinned.path) {
        unawaited(revalidate(book).catchError((Object _) {}));
      }
      return lease;
    }
    final entry = object(store.cached(server, _key(book)));
    final file = _file(entry);
    if (file != null &&
        await file.exists() &&
        (offline || entry['fingerprint'] == _fingerprint(book))) {
      final lease = _lease(file);
      unawaited(
        file.setLastModified(DateTime.now()).catchError((Object _) => file),
      );
      if (!offline &&
          DateTime.now().millisecondsSinceEpoch - integer(entry['validated']) >
              const Duration(minutes: 30).inMilliseconds) {
        unawaited(revalidate(book).catchError((Object _) {}));
      }
      scheduleTrim();
      return lease;
    }
    if (offline) {
      throw const ApiFailure(
        'This book has not been downloaded.',
        offline: true,
      );
    }
    final loaded = await _load(book);
    if (_closed) throw StateError('Document cache closed');
    final lease = _lease(loaded);
    scheduleTrim();
    return lease;
  }

  Future<File> _adoptLegacy(Book book, File original) async {
    // Older previews put unpinned reader originals in the download directory.
    // Transfer ownership before migrating so a queued download cannot race it.
    if (store.download(server, book.id) != null ||
        _active.containsKey(original.path) ||
        !store.claimTransfer(server, book.id, _owner)) {
      return original;
    }
    try {
      if (store.download(server, book.id) != null) return original;
      await directory.create(recursive: true);
      final target = File(
        p.join(
          directory.path,
          '${sha256.convert(utf8.encode(book.id))}-${DateTime.now().microsecondsSinceEpoch}.${book.format}',
        ),
      );
      await original.rename(target.path);
      if (!_closed && !store.accountRemoved(server)) {
        store.cache(server, _key(book), {
          'file': p.basename(target.path),
          'fingerprint': _fingerprint(book),
          'validated': 0,
        });
      }
      scheduleTrim();
      return target;
    } on FileSystemException {
      // Another Windows reader may still have the old file open.
      return original;
    } finally {
      try {
        store.releaseTransfer(server, book.id, _owner);
      } catch (_) {}
    }
  }

  Future<File> _load(
    Book book, {
    Json? headers,
  }) => _loads.putIfAbsent(book.id, () async {
    final resource = 'document:${book.id}';
    var leased = false;
    Timer? heartbeat;
    try {
      while (!leased) {
        if (_closed || store.accountRemoved(server)) {
          throw StateError('Document cache closed');
        }
        leased = store.claimTransfer(server, resource, _owner);
        if (!leased) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!_closed) store.refreshTransfer(server, resource, _owner);
      });
      final current = object(store.cached(server, _key(book)));
      final previous = _file(current);
      if (previous != null &&
          await previous.exists() &&
          current['fingerprint'] == _fingerprint(book) &&
          DateTime.now().millisecondsSinceEpoch -
                  integer(current['validated']) <
              const Duration(minutes: 30).inMilliseconds &&
          (headers == null ||
              (text(headers['etag']).isNotEmpty &&
                  headers['etag'] == current['etag']))) {
        return previous;
      }
      final pendingKey = 'documentPending:${book.id}';
      final pending = object(store.cached(server, pendingKey));
      final partial = pending['fingerprint'] == _fingerprint(book)
          ? _file(pending)
          : null;
      final file = partial != null && partial.path != previous?.path
          ? partial
          : File(
              p.join(
                directory.path,
                '${sha256.convert(utf8.encode(book.id))}-${DateTime.now().microsecondsSinceEpoch}.${book.format}',
              ),
            );
      store.cache(server, pendingKey, {
        'file': p.basename(file.path),
        'fingerprint': _fingerprint(book),
      });
      final head = headers == null
          ? _head(book).catchError((Object _) => <String, dynamic>{})
          : Future.value(headers);
      await api.download(
        '/api/v1/books/${Uri.encodeComponent(book.id)}/file',
        file,
      );
      final validators = await head;
      if (!_closed && !store.accountRemoved(server)) {
        store.cache(server, _key(book), {
          ...validators,
          'file': p.basename(file.path),
          'fingerprint': _fingerprint(book),
          'validated': DateTime.now().millisecondsSinceEpoch,
        });
        store.cache(server, pendingKey, null);
      }
      return file;
    } finally {
      heartbeat?.cancel();
      if (leased) {
        try {
          store.releaseTransfer(server, resource, _owner);
        } catch (_) {}
      }
      _loads.remove(book.id);
    }
  });
  Future<Json> _head(Book book, [Json entry = const {}]) async {
    final response = await api.send(
      '/api/v1/books/${Uri.encodeComponent(book.id)}/file',
      method: 'HEAD',
      acceptedStatuses: const {304},
      extra: {
        'Accept': '*/*',
        if (text(entry['etag']).isNotEmpty)
          'If-None-Match': text(entry['etag'])
        else if (text(entry['modified']).isNotEmpty)
          'If-Modified-Since': text(entry['modified']),
      },
    );
    await response.stream.drain<void>();
    return {
      'status': response.statusCode,
      'etag': response.headers['etag'],
      'modified': response.headers['last-modified'],
      'length': response.headers['content-length'],
    };
  }

  Future<void> revalidate(Book book) =>
      _refreshes.putIfAbsent(book.id, () async {
        try {
          if (_closed) return;
          final entry = object(store.cached(server, _key(book)));
          final headers = await _head(book, entry);
          if (_closed || store.accountRemoved(server)) return;
          final same =
              headers['status'] == 304 ||
              (text(entry['etag']).isNotEmpty &&
                  entry['etag'] == headers['etag']) ||
              (text(entry['modified']).isNotEmpty &&
                  entry['modified'] == headers['modified'] &&
                  entry['length'] == headers['length']);
          if (same && _file(entry)?.existsSync() == true) {
            store.cache(server, _key(book), {
              ...entry,
              'validated': DateTime.now().millisecondsSinceEpoch,
            });
          } else {
            await _load(book, headers: headers);
            scheduleTrim();
          }
        } finally {
          _refreshes.remove(book.id);
        }
      });
  void scheduleTrim() {
    if (_closed || _trimTimer != null) return;
    _trimTimer = Timer(const Duration(seconds: 2), () {
      _trimTimer = null;
      unawaited(trim().catchError((Object _) {}));
    });
  }

  Future<void> trim({bool clear = false}) async {
    if (_closed || !await directory.exists()) return;
    final files = <(File, FileStat)>[];
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is! File ||
          !['.pdf', '.epub'].contains(p.extension(entity.path))) {
        continue;
      }
      final stat = await entity.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      files.add((entity, stat));
      total += stat.size;
    }
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final entry in files) {
      if (!clear && total <= budget) break;
      if (_active.containsKey(entry.$1.path)) continue;
      try {
        await entry.$1.delete();
        total -= entry.$2.size;
      } on FileSystemException {
        // Another Windows reader can still hold the immutable source open.
      }
    }
  }

  Future<void> get settled => Future.wait([
    ..._loads.values.map(
      (future) => future.then<void>((_) {}, onError: (Object _) {}),
    ),
    ..._refreshes.values.map(
      (future) => future.then<void>((_) {}, onError: (Object _) {}),
    ),
  ]);

  void close() {
    _closed = true;
    _trimTimer?.cancel();
  }
}
