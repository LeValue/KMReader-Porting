import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:archive/archive_io.dart';
import 'package:kmreader/core/updates/app_updates.dart';

Map<String, dynamic> manifest(List<int> bytes) => {
  'schema': 1,
  'version': '1.0.0',
  'build': 999,
  'source': 'a' * 40,
  'packages': {
    'android': {
      'url': '${updateOrigin}v1.0.0-candidate.9/app.apk',
      'sha256': sha256.convert(bytes).toString(),
      'size': bytes.length,
    },
  },
};
void main() {
  test('update metadata rejects wrong hosts, downgrades and invalid integrity fields', () {
    final valid = manifest([1, 2, 3]);
    expect(AppUpdate.parse(valid, 'android').build, 999);
    for (final change in [
      {'build': 1},
      {'source': 'wrong'},
      {'schema': 2},
    ]) {
      expect(
        () => AppUpdate.parse({...valid, ...change}, 'android'),
        throwsFormatException,
      );
    }
    for (final url in [
      'http://github.com/LeValue/KMReader-Porting/releases/download/tag/app.apk',
      'https://github.com.evil.invalid/LeValue/KMReader-Porting/releases/download/tag/app.apk',
      'https://github.com/other/repo/releases/download/tag/app.apk',
      '${updateOrigin}tag/app.apk?token=bad',
    ]) {
      final data = manifest([1]);
      data['packages']['android']['url'] = url;
      expect(() => AppUpdate.parse(data, 'android'), throwsFormatException);
    }
  });
  test('public feed selects a newer manifest from its exact release', () async {
    final data = manifest([1, 2]);
    final service = AppUpdates(
      client: MockClient((request) async {
        expect(request.headers['authorization'], isNull);
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode([
              {
                'draft': false,
                'tag_name': 'v1.0.0-candidate.9',
                'assets': [
                  {
                    'name': 'kmreader-update.json',
                    'browser_download_url':
                        '${updateOrigin}v1.0.0-candidate.9/kmreader-update.json',
                  },
                ],
              },
            ]),
            200,
          );
        }
        return http.Response(jsonEncode(data), 200);
      }),
    );
    addTearDown(service.close);
    expect((await service.check('android'))?.build, 999);
  });
  test(
    'verified downloads stream to a temporary file and reject corrupt bytes',
    () async {
      final root = Directory.systemTemp.createTempSync('update-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      final bytes = List<int>.generate(8192, (i) => i % 251);
      final update = AppUpdate.parse(manifest(bytes), 'android');
      var corrupt = true, requests = 0;
      final service = AppUpdates(
        client: MockClient((request) async {
          requests++;
          return http.Response.bytes(
            corrupt ? List.filled(bytes.length, 0) : bytes,
            200,
          );
        }),
      );
      addTearDown(service.close);
      await expectLater(
        service.download(update, root, (_, _) {}),
        throwsFormatException,
      );
      expect(root.listSync(), isEmpty);
      corrupt = false;
      final file = await service.download(update, root, (_, _) {});
      expect(await file.readAsBytes(), bytes);
      await service.download(update, root, (_, _) {});
      expect(requests, 2);
    },
  );
  test(
    'Windows updates reject traversal, links and mismatched embedded sources',
    () {
      final root = Directory.systemTemp.createTempSync('windows-update-');
      addTearDown(() => root.deleteSync(recursive: true));
      final update = AppUpdate(
        '1.0.0',
        999,
        'a' * 40,
        Uri.parse('${updateOrigin}tag/app.zip'),
        'b' * 64,
        100,
      );
      void check(String extra, Map<String, dynamic> metadata, bool accepted) {
        final archive = Archive();
        for (final name in [
          'KMReader/kmreader.exe',
          'KMReader/data/app.so',
          'KMReader/kindle/KMReader-Kindle.exe',
        ]) {
          archive.addFile(ArchiveFile(name, 1, [1]));
        }
        final content = utf8.encode(jsonEncode(metadata));
        archive.addFile(
          ArchiveFile(
            'KMReader/data/flutter_assets/assets/build/source.json',
            content.length,
            content,
          ),
        );
        if (extra.isNotEmpty) archive.addFile(ArchiveFile(extra, 1, [2]));
        final file = File('${root.path}/test.zip')
          ..writeAsBytesSync(ZipEncoder().encode(archive));
        if (accepted) {
          validateWindowsUpdate(file.path, update);
        } else {
          expect(
            () => validateWindowsUpdate(file.path, update),
            throwsFormatException,
          );
        }
      }

      final meta = {'source': 'a' * 40, 'version': '1.0.0', 'build': 999};
      check('', meta, true);
      check('KMReader/../../outside', meta, false);
      check('KMReader/case.exe', {
        'source': 'b' * 40,
        'version': '1.0.0',
        'build': 999,
      }, false);
    },
  );
}
