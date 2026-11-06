// Generated from KMReader's own synthetic KFX, never an account publication.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/kindle/conversion.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/features/reader/epub_document.dart';

void verifyNativeKindleWorker() {
  testWidgets('native on-demand worker converts KFX to faithful mapped EPUB', (
    tester,
  ) async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('kindle-worker-');
    if (Platform.isWindows) {
      NativeKindlePreparation.executableOverride =
          '${Directory.current.path}/artifacts/kindle-dist/KMReader-Kindle/KMReader-Kindle.exe';
    }
    try {
      final bytes = gzip.decode(base64Decode(_syntheticKfx));
      await File('${root.path}/base.azw').writeAsBytes(bytes);
      await File('${root.path}/receipt.json').writeAsString(
        jsonEncode({
          'schema': 1,
          'download_state': 'complete',
          'resources': [
            {
              'type': 'KINDLE_MAIN_BASE',
              'file': 'base.azw',
              'bytes': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
            },
          ],
        }),
      );
      final result = await NativeKindlePreparation().prepare(root);
      expect(result['format'], 'epub');
      expect(result['kindle_locator_map'], true);
      final book = EpubDocument.open('${root.path}/ready.epub');
      try {
        final mapping = object(
          jsonDecode(
            utf8.decode(book.resource('META-INF/kmreader-kindle.json')),
          ),
        );
        expect(mapping['entries'], hasLength(2));
        expect(book.chapters, isNotEmpty);
        final text = utf8.decode(book.resource(book.chapters.first.path));
        expect(text, contains('Capitolo sintetico'));
        expect(text, contains('😀'));
      } finally {
        book.close();
      }
      // Exercise the exact Android channel / packaged Windows RPC cover path.
      // All bytes and capabilities are synthetic and remain on loopback.
      final artwork = gzip.decode(base64Decode(_syntheticCover));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$')
            .firstMatch(request.headers.value('range') ?? '');
        if (match == null) {
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        final first = int.parse(match[1]!);
        final last = int.parse(match[2]!).clamp(first, artwork.length - 1);
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes $first-$last/${artwork.length}',
        );
        request.response.headers.set('etag', '"synthetic-cover"');
        request.response.add(artwork.sublist(first, last + 1));
        await request.response.close();
      });
      try {
        final cover = await NativeKindlePreparation().cover([
          'http://127.0.0.1:${server.port}/kindle-cover/${'a' * 32}/0',
        ]);
        expect(base64Decode(text(cover['image'])).take(3), [0xff, 0xd8, 0xff]);
        expect(integer(cover['pages']), greaterThan(0));
      } finally {
        await server.close(force: true);
      }
    } finally {
      NativeKindlePreparation.executableOverride = null;
      await root.delete(recursive: true);
    }
  });
}

const _syntheticKfx =
    'H4sIAAAAAAACA+3czUsUcRjA8fntKFbQC0H32TmL7K75SpfYvBRqhBdxdRjHUSfXnWVmlJYQskxLyLIofEs9RFSHCKHQDgvhoYtdKnqFzbOHEDp2afZFxUqFrn0Hfjy/5+H5/H4z8wc80caGpoD0Q0hSib9KJUmK+THgr40nthFlSSoSW3lFIbb5ddmvjxfykmg+thb6J6Lb+7VC/5vo9v7svfv89X44n4elrfp+fxWP5PPKQn1VSGvfXw9eySxfU2VtOH03c2dotPm05qZ62+24ezV4wK+3jKQfXHdNw7PshBba3IVHXM92UlqoEMPZwzIP5cnD8pQiTyvy/eBReTb4SJ4LvpTng/XyjHpEKnqripKid0rLxR4zVav2dF7oMhNaUjd69C5T6zcd1z9aLe3X431mraoOlG7r05PJuGXouev36k3qqbitd2hutx7ebGrXQ+2VVdWGWR4xjodqwjWd1REjUlUTNjv0UKjdLC/XyyMVeuUfFxvOxhmJvnh8oLWuoalZSMcKv/BD/otzP+CVmBybPVN/ztQ7TEdJOnaXY7qu1W8qbirhdZueZYxetjzxc+jsqcaoeJy+lRkTC47QxJMXjhxz5F3OnhJP/RZxIz2euSnmHHFIzDgiKp45ctvOSBSv5TrE7bQo/uanX8V0UGT5QTE+JopXonrS8uy4rbhWwsu+n62EypSThmEmPKtWMSzPW54vVcyVwTKlrtc+79fW5yYulSlAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUDgb3CP2Rmtf5udoe05O0PbNjsjsPvsjPC/fiEQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIPD/hjuOwUjf+yKeLwRFdoJGLLcN5IZp7AymP4pFRSwFxWexqJ5Y93eBT/4utSqWlF+8Zk8YLokAAA==';

const _syntheticCover =
    'H4sIAAAAAAACA+3cW3ATVRgH8HP2JE3Si5C2IDBFNtsihenUpm16GxyFUJQygiAqSMuySTYlEJqySQvRYcZCodAZi+Um97bI/cGRKgg+ZOQiXoYXQKGFmQrerTNaFLw+1JM0LVOkoDw54/90/nP2nHy/3f2278c+fdosgUwVCJEpIRmEkFI+Czy9Q4nOpYwQHb21tkXneXyf8f3N0bXB3jOXRet32vvXy9H68/b+9eHnGnnaV/esreTWvokntq5nnRfdn8/vs4fPj0f3H+l9X77fwut90X1HWs98lZLOH36sWdnx/RqJKatDmzo21NbPKZH9wcUOn9e/yhLL9+fWhc6u9avOgMdXIWf1XVnr/AGfFpSzorO1YZ0/WBFYoAY8Ttnpq1a1hk23bciOYED1hx/asY9tHcS2iWy7yHZaEtkuSxtrsnSyZksV2yENJrrzEpV1F8S5Ly1Sg0XSIveycrVCrlSci5RyVea38vNXkDKqFW+VWiRJyzP61SmVlV6PU4m85r1qK5Wg16e4ZP8CxdpXVOCyufILrI6cwjy326E4bYU2W36etSDLpjpt+e6cwnzVnedyu/72YKfWe4+KKq93eVnxtFlzKBkS/dQXezqOfIAzdGvDrqlPzVQVl6qJlZqvXFP9fk+1KvZ9tPoVngD9s/bpSdPt9GDo1Y4G2qpRmR46qrFSjZWxAxqbP/ADttE3eB19JdTYsY42afQBukOjdvqmxuYNjKi+M1JB14eo/jO+vEK3W2iYJ9DGBqo/a1cqPQGf1yf6PRWB8Ev6xKxMcYLTqVYEPEWi0xMInGrOENWzNZli8WLfQr7X1bTl5UwREBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBDwNniPszPK7nR2hnzPszPkfmdnCHc/O8N6vx0CAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAv6/4YDHYIQ2X6ZHWi00fIJGaeRSiBymMTDYfokeE+lxC22nx6TxXfxKaONXwav0+F2O6NhIWzQ6ku7VmML2ScJstl9itXcs727rvkoGl0yeMplQSgjlf6T7CrETY0yMIUZvNBgMJpMxNj45IT4uLn54YtKg5JEjRj00ckRKipiWOUaUMlJTUtLzx2ZkWXNzc0eNKXy0IHt8Zk5udvgm1GQyxcfFD0tIGJZtSbFk/+vR/R4xG1ktb4BKRDBTZqbdp8ko/p56GhkkOqjAdPoYg9EUG8cLjgwmAmVM0DG9Xqfjvy7nvxOdWZ9osU6ISZqhGKQlydk1jS3G1ImHTwyZea4rLcehrTDFDn1w2PARox8ekz52XK4tL7+gsMg+qXjyE09OKXlm1rPPPT97zgtOl+ouX+BZ6A9UVS9dFnxxZe2q1XVr1tav37Bx0+bXtmzdtvv1PXv37T9w8FDrW28fOfrOsePvnjx1+v0zH3z40cfnL3zy6cVLbe2Xr33+xZdfff3Nt991Xv/p5xs3f/n1t9//CPdFCaO94459mXlfgk7HdIZwX1RYGi4w6/QWa0zihBkGZUmSlF1jTJ7Y2HL4hCk1Z2bXEId2LnZoWu610dfDrUU6+2eNrbivzvoau9XXZRLPKP/nMTN5jNwcl747tOzGyfr0ZgFBEARBEARBEARBEARBEARBEARBEARBEAT5T2VQd/tfDqUchByuAAA=';
