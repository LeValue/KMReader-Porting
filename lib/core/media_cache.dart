import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'store.dart';

enum MediaCacheKind { pages, covers }

class MediaCacheStats {
  const MediaCacheStats(this.bytes, this.entries);
  final int bytes, entries;
}

class MediaCache {
  MediaCache(this.root, this.store, this.server);
  final Directory root;
  final LocalStore store;
  final String server;
  Future<void>? _migration;
  static MediaCacheKind kind(String path) => path.contains('/thumbnail')
      ? MediaCacheKind.covers
      : MediaCacheKind.pages;
  String hash(String key) => sha256.convert(utf8.encode(key)).toString();
  Directory account(String id) => Directory(p.join(root.path, id, 'cache'));
  Directory directory(MediaCacheKind kind, [String? id]) =>
      Directory(p.join(account(id ?? server).path, kind.name));
  File file(String path) =>
      File(p.join(directory(kind(path)).path, hash(path)));
  int epoch(String id, MediaCacheKind kind) =>
      store.setting<int>('imageCacheEpoch:$id:${kind.name}') ?? 0;
  int budget(MediaCacheKind kind) => kind == MediaCacheKind.pages
      ? (store.setting<int>('maxPageCacheSize') ?? 8).clamp(1, 20) *
            1024 *
            1024 *
            1024
      : (store.setting<int>('maxCoverCacheSize') ?? 512).clamp(128, 8192) *
            1024 *
            1024;

  Future<void> migrate() => _migration ??= _migrate();
  Future<void> _migrate() async {
    final legacy = account(server);
    if (!await legacy.exists()) return;
    final covers = store.db
        .select('SELECT path FROM image_versions WHERE server=?', [server])
        .map((row) => row['path'] as String)
        .where((path) => kind(path) == MediaCacheKind.covers)
        .map(hash)
        .toSet();
    await for (final entry in legacy.list()) {
      if (entry is! File || entry.path.endsWith('.part')) continue;
      final name = p.basename(entry.path);
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(name)) continue;
      final target = File(
        p.join(
          directory(
            covers.contains(name)
                ? MediaCacheKind.covers
                : MediaCacheKind.pages,
          ).path,
          name,
        ),
      );
      try {
        if (store.accountRemoved(server)) return;
        await target.parent.create(recursive: true);
        if (!await target.exists()) {
          await entry.rename(target.path);
        } else {
          await entry.delete();
        }
      } on FileSystemException {
        // Another worker may already have migrated this entry.
      }
    }
  }

  Future<List<(File, FileStat)>> _files(MediaCacheKind kind, String id) async {
    final files = <(File, FileStat)>[];
    final roots = [
      directory(kind, id),
      if (kind == MediaCacheKind.pages) account(id),
      if (kind == MediaCacheKind.pages)
        Directory(p.join(account(id).path, 'upscaled')),
    ];
    for (final directory in roots) {
      if (!await directory.exists()) continue;
      await for (final entry in directory.list()) {
        if (entry is! File || entry.path.endsWith('.part')) continue;
        final stat = await entry.stat();
        if (stat.type == FileSystemEntityType.file) files.add((entry, stat));
      }
    }
    return files;
  }

  Future<MediaCacheStats> stats(MediaCacheKind kind) async {
    await migrate();
    final files = await _files(kind, server);
    return MediaCacheStats(
      files.fold(0, (sum, file) => sum + file.$2.size),
      files.length,
    );
  }

  Future<void> trim({
    MediaCacheKind? kind,
    bool clear = false,
    bool allAccounts = false,
  }) async {
    final accounts = allAccounts || !clear
        ? {server, ...store.servers.map((account) => account.id)}
        : {server};
    final caches = [
      for (final id in accounts)
        id == server ? this : MediaCache(root, store, id),
    ];
    for (final cache in caches) {
      await cache.migrate();
    }
    for (final selected in kind == null ? MediaCacheKind.values : [kind]) {
      final files = <(File, FileStat)>[];
      for (final cache in caches) {
        if (clear) {
          store.setSetting(
            'imageCacheEpoch:${cache.server}:${selected.name}',
            cache.epoch(cache.server, selected) + 1,
          );
        }
        files.addAll(await cache._files(selected, cache.server));
      }
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      var total = files.fold(0, (sum, file) => sum + file.$2.size);
      final limit = clear ? 0 : budget(selected);
      for (final file in files) {
        if (total <= limit) break;
        try {
          await file.$1.delete();
          total -= file.$2.size;
        } on FileSystemException {
          /* Windows may still hold an active image. */
        }
      }
    }
  }
}
