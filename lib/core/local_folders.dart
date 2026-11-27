import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'local_library.dart';
import 'models.dart';

class LocalFolder {
  const LocalFolder(this.id, this.name);
  final String id;
  final String name;
}

/// Folder access stays tied to a user's picker grant. The local library owns
/// its copies and keeps progress by content digest even when a source disappears.
class LocalFolders extends ChangeNotifier with WidgetsBindingObserver {
  LocalFolders(this.library);
  final LocalLibrary library;
  static const _key = 'localImportFolders';
  static const _channel = MethodChannel('dev.levalue.kmreader/local_folders');
  final _watchers = <String, StreamSubscription<FileSystemEvent>?>{};
  Timer? _debounce;
  Future<void>? _scan;
  bool _started = false;
  bool _disposed = false;
  bool _scanAgain = false;
  final failures = <String, int>{};

  bool get supported => Platform.isAndroid || Platform.isWindows;
  bool get scanning => _scan != null;
  List<LocalFolder> get folders =>
      (library.store.setting<List<dynamic>>(_key) ?? []).map((row) {
        final value = object(row);
        return LocalFolder(text(value['id']), text(value['name']));
      }).toList();

  void start() {
    if (_started || !supported) return;
    _started = true;
    library.store.db.execute('''
      CREATE TABLE IF NOT EXISTS local_folder_files(
        folder TEXT NOT NULL, entry TEXT NOT NULL, stamp TEXT NOT NULL,
        PRIMARY KEY(folder, entry))
    ''');
    WidgetsBinding.instance.addObserver(this);
    if (folders.isNotEmpty) unawaited(refresh());
  }

  Future<void> add() async {
    start();
    LocalFolder? folder;
    if (Platform.isAndroid) {
      final value = await _channel.invokeMapMethod<String, String>('select');
      if (value != null) folder = LocalFolder(value['id']!, value['name']!);
    } else if (Platform.isWindows) {
      final path = await getDirectoryPath();
      if (path != null) {
        final canonical = await Directory(path).resolveSymbolicLinks();
        folder = LocalFolder(canonical, p.basename(canonical));
      }
    }
    if (folder == null || _disposed) return;
    final current = folders;
    if (!current.any((source) => source.id == folder!.id)) {
      _save([...current, folder]);
    }
    await refresh();
  }

  Future<void> remove(LocalFolder folder) async {
    _save(folders.where((source) => source.id != folder.id));
    failures.remove(folder.id);
    await _watchers.remove(folder.id)?.cancel();
    library.store.db.execute('DELETE FROM local_folder_files WHERE folder=?', [
      folder.id,
    ]);
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('forget', folder.id);
    }
  }

  void _save(Iterable<LocalFolder> values) {
    library.store.setSetting(_key, [
      for (final folder in values) {'id': folder.id, 'name': folder.name},
    ]);
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && folders.isNotEmpty) {
      _watchers.removeWhere((_, watcher) => watcher == null);
      unawaited(refresh());
    }
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () => unawaited(refresh()));
  }

  Future<void> refresh() {
    if (!_started || _disposed) return Future.value();
    final current = _scan;
    if (current != null) {
      _scanAgain = true;
      return current;
    }
    final next =
        Future<void>.microtask(() async {
          do {
            _scanAgain = false;
            for (final folder in folders) {
              if (_disposed) break;
              await _scanFolder(folder);
            }
          } while (_scanAgain && !_disposed);
        }).whenComplete(() {
          _scan = null;
          if (!_disposed) notifyListeners();
        });
    _scan = next;
    notifyListeners();
    return next;
  }

  Future<void> _scanFolder(LocalFolder folder) async {
    var failed = 0;
    try {
      if (Platform.isWindows && !_watchers.containsKey(folder.id)) {
        try {
          _watchers[folder.id] = Directory(folder.id)
              .watch(recursive: true)
              .listen(
                (_) => _schedule(),
                onError: (Object _) {
                  unawaited(_watchers.remove(folder.id)?.cancel());
                  _watchers[folder.id] = null;
                  _schedule();
                },
                onDone: () {
                  _watchers[folder.id] = null;
                  _schedule();
                },
              );
        } on FileSystemException {
          // Some providers only support scanning on request or app resume.
          _watchers[folder.id] = null;
        }
      }
      final db = library.store.db;
      final previous = {
        for (final row in db.select(
          'SELECT entry, stamp FROM local_folder_files WHERE folder=?',
          [folder.id],
        ))
          row['entry'] as String: row['stamp'] as String,
      };
      bool retained() =>
          !_disposed && folders.any((source) => source.id == folder.id);
      final entries = Platform.isAndroid
          ? _androidEntries(folder)
          : _windowsEntries(folder);
      await for (final entry in entries) {
        if (!retained()) return;
        if (!LocalLibrary.extensions.contains(
          p.extension(entry.name).toLowerCase().replaceFirst('.', ''),
        )) {
          continue;
        }
        final saved = previous.remove(entry.id);
        if (saved == entry.stamp) continue;
        File? staged;
        try {
          if (Platform.isAndroid) {
            final path = await _channel.invokeMethod<String>('stage', {
              'folder': folder.id,
              'entry': entry.id,
            });
            if (path == null) throw StateError('Folder source unavailable');
            staged = File(path);
          }
          if (!retained()) return;
          await library.importFile(
            XFile(staged?.path ?? entry.id),
            displayName: entry.name,
          );
          if (!retained()) return;
          db.execute(
            'INSERT OR REPLACE INTO local_folder_files VALUES(?,?,?)',
            [folder.id, entry.id, entry.stamp],
          );
        } on Exception {
          failed++;
        } finally {
          if (staged != null) {
            try {
              await staged.delete();
            } on FileSystemException {
              // The cache file may have already been removed.
            }
          }
        }
      }
      if (retained()) {
        for (final entry in previous.keys) {
          db.execute(
            'DELETE FROM local_folder_files WHERE folder=? AND entry=?',
            [folder.id, entry],
          );
        }
      }
    } on Exception {
      failed++;
    }
    if (!_disposed && folders.any((source) => source.id == folder.id)) {
      if (failed == 0) {
        failures.remove(folder.id);
      } else {
        failures[folder.id] = failed;
      }
    }
  }

  Stream<_FolderEntry> _androidEntries(LocalFolder folder) async* {
    final entries = await _channel.invokeListMethod<Object?>('list', folder.id);
    for (final value in entries ?? []) {
      final row = object(value);
      yield _FolderEntry(
        text(row['id']),
        text(row['name']),
        text(row['stamp']),
      );
    }
  }

  Stream<_FolderEntry> _windowsEntries(LocalFolder folder) async* {
    await for (final entity in Directory(
      folder.id,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      final age = DateTime.now().difference(stat.modified);
      if (!age.isNegative && age < const Duration(seconds: 2)) {
        _schedule();
        continue;
      }
      yield _FolderEntry(
        entity.path,
        p.basename(entity.path),
        '${stat.size}:${stat.modified.microsecondsSinceEpoch}',
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final watcher in _watchers.values) {
      unawaited(watcher?.cancel());
    }
    _watchers.clear();
    super.dispose();
  }
}

class _FolderEntry {
  const _FolderEntry(this.id, this.name, this.stamp);
  final String id;
  final String name;
  final String stamp;
}
