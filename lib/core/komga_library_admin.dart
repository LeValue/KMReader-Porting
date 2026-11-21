import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'models.dart';
import 'repository.dart';

const komgaUploadPrefix = '/kmreader-admin/v1';

class KomgaLibraryAdmin {
  KomgaLibraryAdmin(this.repository);
  final Repository repository;
  void requireAdmin() {
    if (repository.profile.source != 'komga' || !repository.profile.admin) {
      throw const ApiFailure('Admin access required.', status: 403);
    }
    if (repository.offline || repository.closed) {
      throw const ApiFailure(
        'Reconnect to edit server content.',
        offline: true,
      );
    }
  }

  Future<Json> uploadLibraries() {
    requireAdmin();
    return repository.api.request('$komgaUploadPrefix/libraries').then(object);
  }

  String _libraryEndpoint(String library, String action) =>
      '$komgaUploadPrefix/libraries/${Uri.encodeComponent(library)}/$action';

  Future<Json> folders(String library, String parent, {String? after}) {
    requireAdmin();
    return repository.api
        .request(
          _libraryEndpoint(library, 'folders'),
          query: {if (parent.isNotEmpty) 'parent': parent, 'after': ?after},
        )
        .then(object);
  }

  Future<Json> createFolder(String library, String parent, String name) {
    requireAdmin();
    return repository.api
        .request(
          _libraryEndpoint(library, 'folders'),
          method: 'POST',
          body: {'parent': parent, 'name': name},
        )
        .then(object);
  }

  Future<Json> komgaFolders(String library, String parent) async {
    requireAdmin();
    final detail = object(
      await repository.api.request(
        '/api/v1/libraries/${Uri.encodeComponent(library)}',
      ),
    );
    final root = text(detail['root']);
    final paths = p.Context(
      style: root.startsWith('/') ? p.Style.posix : p.Style.windows,
    );
    if (!paths.isAbsolute(root)) {
      throw const ApiFailure('The server returned an unexpected response.');
    }
    final parts = parent.isEmpty ? const <String>[] : parent.split('/');
    for (final part in parts) {
      validateComponent(part);
    }
    final directory = paths.normalize(paths.joinAll([root, ...parts]));
    if (!paths.equals(root, directory) && !paths.isWithin(root, directory)) {
      throw const ApiFailure('Invalid folder or filename');
    }
    final listing = object(
      await repository.api.request(
        '/api/v1/filesystem',
        method: 'POST',
        body: {'path': directory, 'showFiles': false},
      ),
    );
    final names = <String>{};
    for (final entry in (listing['directories'] as List? ?? []).map(object)) {
      final name = text(entry['name']);
      try {
        validateComponent(name);
      } on ApiFailure {
        continue;
      }
      final child = paths.normalize(paths.join(directory, name));
      if (paths.equals(paths.dirname(child), directory) &&
          paths.equals(child, text(entry['path']))) {
        names.add(name);
      }
    }
    return {'folders': names.toList()..sort()};
  }

  Future<void> enrollLibrary(String library) async {
    requireAdmin();
    final result = object(
      await repository.api.request(
        _libraryEndpoint(library, 'enroll'),
        method: 'POST',
      ),
    );
    if (result['id'] != library) {
      throw const ApiFailure('The server returned an unexpected response.');
    }
  }

  Future<void> scanBatch(String library, List<String> uploads) async {
    requireAdmin();
    final result = object(
      await repository.api.request(
        _libraryEndpoint(library, 'scan'),
        method: 'POST',
        body: {'uploads': uploads},
      ),
    );
    if (result['scan_requested'] != true) {
      throw const ApiFailure('The server returned an unexpected response.');
    }
  }

  Future<Json> uploadStatus(String id) {
    requireAdmin();
    return repository.api
        .request('$komgaUploadPrefix/uploads/${Uri.encodeComponent(id)}')
        .then(object);
  }

  Future<Json> scanUpload(String id) {
    requireAdmin();
    return repository.api
        .request(
          '$komgaUploadPrefix/uploads/${Uri.encodeComponent(id)}/scan',
          method: 'POST',
        )
        .then(object);
  }

  Future<Json> upload(
    XFile file,
    Json operation,
    void Function(int) progress,
    Future<void> abort,
  ) {
    requireAdmin();
    return repository.api.uploadFile(
      '$komgaUploadPrefix/uploads/${Uri.encodeComponent(text(operation['id']))}',
      bytes: file.openRead(),
      length: integer(operation['size']),
      progress: progress,
      query: {
        if (operation['deferScan'] == true) 'defer_scan': '1',
        for (final key in ['library', 'folder', 'filename'])
          key: operation[key],
      },
      extra: {'X-Content-SHA256': text(operation['sha256'])},
      abortTrigger: abort,
    );
  }

  Future<void> cover(
    String kind,
    String id,
    XFile file,
    Future<void> abort,
  ) async {
    requireAdmin();
    if (!['books', 'series'].contains(kind)) {
      throw ArgumentError('Unsupported cover');
    }
    final size = await file.length();
    if (size <= 0 || size > 20 * 1024 * 1024) {
      throw const ApiFailure('Choose a cover smaller than 20 MB.');
    }
    await repository.api.uploadFile(
      '/api/v1/$kind/${Uri.encodeComponent(id)}/thumbnails',
      query: {'selected': true},
      bytes: file.openRead(),
      length: size,
      progress: (_) {},
      multipartFilename: file.name,
      abortTrigger: abort,
    );
    await _coverChanged(kind, id);
  }

  String _coverPath(String kind, String id) {
    requireAdmin();
    if (!['books', 'series'].contains(kind) || id.isEmpty) {
      throw ArgumentError('Unsupported cover');
    }
    return '/api/v1/$kind/${Uri.encodeComponent(id)}/thumbnails';
  }

  Future<List<Json>> covers(String kind, String id) async {
    final value = await repository.api.request(_coverPath(kind, id));
    if (value is! List) {
      throw const ApiFailure('The server returned an unexpected response.');
    }
    final owner = kind == 'books' ? 'bookId' : 'seriesId';
    final seen = <String>{};
    return value.map((entry) {
      final row = object(entry);
      if (row[owner] != id ||
          row['id'] is! String ||
          text(row['id']).isEmpty ||
          !seen.add(text(row['id'])) ||
          row['selected'] is! bool) {
        throw const ApiFailure('The server returned an unexpected response.');
      }
      return row;
    }).toList();
  }

  Future<void> selectCover(String kind, String id, String coverId) async {
    final rows = await covers(kind, id);
    final row = rows.where((row) => row['id'] == coverId).firstOrNull;
    if (row == null) {
      throw const ApiFailure('This cover is no longer available.');
    }
    if (row['selected'] == true) {
      await _coverChanged(kind, id);
      return;
    }
    await repository.api.request(
      '${_coverPath(kind, id)}/${Uri.encodeComponent(coverId)}/selected',
      method: 'PUT',
    );
    await _coverChanged(kind, id);
  }

  Future<void> removeCover(String kind, String id, String coverId) async {
    final rows = await covers(kind, id);
    final row = rows.where((row) => row['id'] == coverId).firstOrNull;
    // A lost DELETE response is reconciled by this read; never replay it.
    if (row == null) {
      await _coverChanged(kind, id);
      return;
    }
    if (row['type'] != 'USER_UPLOADED') {
      throw const ApiFailure('Only uploaded covers can be removed.');
    }
    await repository.api.request(
      '${_coverPath(kind, id)}/${Uri.encodeComponent(coverId)}',
      method: 'DELETE',
    );
    await _coverChanged(kind, id);
  }

  Future<void> _coverChanged(String kind, String id) async {
    // A successful mutation stays successful if cache maintenance fails.
    final changed = {'/api/v1/$kind/${Uri.encodeComponent(id)}/thumbnail'};
    try {
      await repository.invalidateImage(
        '/api/v1/$kind/${Uri.encodeComponent(id)}/thumbnail',
      );
      if (kind == 'books') {
        final book = object(
          await repository.api.request(
            '/api/v1/books/${Uri.encodeComponent(id)}',
          ),
        );
        final series = text(book['seriesId']);
        if (series.isNotEmpty) {
          changed.add(
            '/api/v1/series/${Uri.encodeComponent(series)}/thumbnail',
          );
          await repository.invalidateImage(
            '/api/v1/series/${Uri.encodeComponent(series)}/thumbnail',
          );
        }
      }
    } catch (_) {}
    if (!repository.closed) repository.imageChanges.value = changed;
    repository.refreshContent();
  }

  Future<void> deleteBook(String id) async {
    requireAdmin();
    await repository.api.request(
      '/api/v1/books/${Uri.encodeComponent(id)}/file',
      method: 'DELETE',
    );
    repository.refreshContent();
  }

  static void validateDestination(String folder, String filename) {
    validateFolder(folder);
    validateComponent(filename);
    if (!RegExp(
      r'\.(cbz|cbr|epub|pdf)$',
      caseSensitive: false,
    ).hasMatch(filename)) {
      throw const ApiFailure('Use CBZ, CBR, EPUB or PDF');
    }
  }

  static void validateFolder(String folder) {
    final parts = folder.split('/');
    if (parts.length > 16 || utf8.encode(folder).length > 1024) {
      throw const ApiFailure('Invalid folder or filename');
    }
    for (final part in parts) {
      validateComponent(part);
    }
  }

  static void validateComponent(String value) {
    if (value.trim().isEmpty ||
        value.startsWith('.') ||
        RegExp(r'[/\\\x00-\x1f]').hasMatch(value) ||
        utf8.encode(value).length > 240) {
      throw const ApiFailure('Invalid folder or filename');
    }
  }

  static Future<String> digest(XFile file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}
