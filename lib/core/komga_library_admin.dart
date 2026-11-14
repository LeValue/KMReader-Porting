import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:crypto/crypto.dart';

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
    final parts = folder.split('/');
    if (parts.length > 16 || utf8.encode(folder).length > 1024) {
      throw const ApiFailure('Invalid folder or filename');
    }
    for (final value in [...parts, filename]) {
      if (value.trim().isEmpty ||
          value.startsWith('.') ||
          RegExp(r'[/\\\x00-\x1f]').hasMatch(value) ||
          utf8.encode(value).length > 240) {
        throw const ApiFailure('Invalid folder or filename');
      }
    }
    if (!RegExp(
      r'\.(cbz|cbr|epub|pdf)$',
      caseSensitive: false,
    ).hasMatch(filename)) {
      throw const ApiFailure('Use CBZ, CBR, EPUB or PDF');
    }
  }

  static Future<String> digest(XFile file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}
