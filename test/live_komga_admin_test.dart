import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/catalog_tools.dart';
import 'package:kmreader/core/komga_library_admin.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final env = Platform.environment;
  test(
    'real Komga 1.30: upload via same-origin proxy, metadata, cover, duplicate and deletion',
    () async {
      final base = env['KMREADER_ADMIN_URL']!;
      final directory = Directory.systemTemp.createTempSync(
        'komga-admin-client-',
      );
      final store = LocalStore(sqlite3.openInMemory());
      store.setSetting('enableReadListSync', false);
      final api = KomgaApi(
        Uri.parse(base),
        authentication: Authentication.password,
        credential: base64Encode(
          utf8.encode(
            '${env['KMREADER_ADMIN_EMAIL']}:${env['KMREADER_ADMIN_PASSWORD']}',
          ),
        ),
      );
      final repo = Repository(
        profile: ServerProfile(
          id: 'synthetic-admin',
          name: 'Disposable',
          url: base,
          email: '',
          authentication: Authentication.password,
          admin: true,
        ),
        api: api,
        directory: directory,
        store: store,
      );
      final admin = KomgaLibraryAdmin(repo);
      try {
        final dto = await admin.uploadLibraries();
        expect(
          (dto['libraries'] as List).any(
            (value) => value['id'] == env['KMREADER_ADMIN_LIBRARY'],
          ),
          true,
        );
        final file = XFile(env['KMREADER_ADMIN_FIXTURE']!);
        final operation = {
          'id': 'd31831ef-6589-4d67-a434-dc32b4874e28',
          'library': env['KMREADER_ADMIN_LIBRARY'],
          'folder': 'Publisher/New Series',
          'filename': 'Uploaded.cbz',
          'size': await file.length(),
          'sha256': await KomgaLibraryAdmin.digest(file),
        };
        final receipt = await admin.upload(
          file,
          operation,
          (_) {},
          Completer<void>().future,
        );
        expect(receipt['status'], 'uploaded');
        expect(receipt['scan_requested'], true);
        expect(
          (await admin.uploadStatus(operation['id'] as String))['sha256'],
          operation['sha256'],
        );
        final target = File(
          '${env['KMREADER_ADMIN_ROOT']}/Publisher/New Series/Uploaded.cbz',
        );
        expect(await target.readAsBytes(), await file.readAsBytes());
        CatalogItem? book;
        for (var attempt = 0; attempt < 120; attempt++) {
          final page = await api.catalog('books');
          if (page.items.isNotEmpty &&
              page.items.first.book.media['status'] == 'READY') {
            book = page.items.first;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(
          book,
          isNotNull,
          reason: 'Komga must index and analyze the uploaded comic',
        );
        final selected = book!;
        final before = object(
          (await api.request('/api/v1/books/${selected.id}'))['metadata'],
        );
        await CatalogTools(repo).updateMetadata('books', selected.id, {
          'title': 'Edited remotely',
          'titleLock': true,
          'tags': ['remote-test'],
          'tagsLock': true,
        }, original: before);
        expect(
          (await api.request(
            '/api/v1/books/${selected.id}',
          ))['metadata']['title'],
          'Edited remotely',
        );
        final changedCovers = <String>{};
        repo.imageChanges.addListener(
          () => changedCovers.addAll(repo.imageChanges.value),
        );
        await admin.cover(
          'books',
          selected.id,
          XFile(env['KMREADER_ADMIN_COVER']!),
          Completer<void>().future,
        );
        expect(
          changedCovers,
          contains('/api/v1/books/${selected.id}/thumbnail'),
        );
        expect(
          changedCovers,
          contains(
            '/api/v1/series/${selected.book.json['seriesId']}/thumbnail',
          ),
        );
        final posters = await api.request(
          '/api/v1/books/${selected.id}/thumbnails',
        ) as List;
        expect(
          posters.any(
            (value) =>
                value['selected'] == true && value['type'] == 'USER_UPLOADED',
          ),
          true,
        );
        final response = await api.send(
          '/api/v1/books/${selected.id}/thumbnail',
          extra: {'Accept': 'image/*'},
        );
        final cover = image.decodeImage(await response.stream.toBytes())!;
        final pixel = cover.getPixel(cover.width ~/ 2, cover.height ~/ 2);
        expect(pixel.b, greaterThan(200));
        expect(pixel.r, lessThan(50));
        final seriesId = text(selected.book.json['seriesId']);
        await admin.cover(
          'series',
          seriesId,
          XFile(env['KMREADER_ADMIN_COVER']!),
          Completer<void>().future,
        );
        final seriesPosters =
            await api.request('/api/v1/series/$seriesId/thumbnails') as List;
        expect(
          seriesPosters.any(
            (value) =>
                value['selected'] == true && value['type'] == 'USER_UPLOADED',
          ),
          true,
        );
        final duplicate = {
          ...operation,
          'id': 'c1f965d9-388e-44ed-b49f-5dbac75c6469',
        };
        await expectLater(
          admin.upload(file, duplicate, (_) {}, Completer<void>().future),
          throwsA(isA<ApiFailure>()),
        );
        expect(await target.readAsBytes(), await file.readAsBytes());
        await admin.deleteBook(selected.id);
        for (
          var attempt = 0;
          attempt < 120 && await target.exists();
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(
          await target.exists(),
          false,
          reason:
              'The native Komga deletion task must remove the original file',
        );
      } finally {
        repo.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
    skip: env['KMREADER_KOMGA_ADMIN_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
