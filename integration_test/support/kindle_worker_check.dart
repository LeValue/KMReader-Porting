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
    } finally {
      NativeKindlePreparation.executableOverride = null;
      await root.delete(recursive: true);
    }
  });
}

const _syntheticKfx =
    'H4sIAAAAAAACA+3czUsUcRjA8fntKFbQC0H32TmL7K75SpfYvBRqhBdxdRjHUSfXnWVmlJYQskxLyLIofEs9RFSHCKHQDgvhoYtdKnqFzbOHEDp2afZFxUqFrn0Hfjy/5+H5/H4z8wc80caGpoD0Q0hSib9KJUmK+THgr40nthFlSSoSW3lFIbb5ddmvjxfykmg+thb6J6Lb+7VC/5vo9v7svfv89X44n4elrfp+fxWP5PPKQn1VSGvfXw9eySxfU2VtOH03c2dotPm05qZ62+24ezV4wK+3jKQfXHdNw7PshBba3IVHXM92UlqoEMPZwzIP5cnD8pQiTyvy/eBReTb4SJ4LvpTng/XyjHpEKnqripKid0rLxR4zVav2dF7oMhNaUjd69C5T6zcd1z9aLe3X431mraoOlG7r05PJuGXouev36k3qqbitd2hutx7ebGrXQ+2VVdWGWR4xjodqwjWd1REjUlUTNjv0UKjdLC/XyyMVeuUfFxvOxhmJvnh8oLWuoalZSMcKv/BD/otzP+CVmBybPVN/ztQ7TEdJOnaXY7qu1W8qbirhdZueZYxetjzxc+jsqcaoeJy+lRkTC47QxJMXjhxz5F3OnhJP/RZxIz2euSnmHHFIzDgiKp45ctvOSBSv5TrE7bQo/uanX8V0UGT5QTE+JopXonrS8uy4rbhWwsu+n62EypSThmEmPKtWMSzPW54vVcyVwTKlrtc+79fW5yYulSlAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUDgb3CP2Rmtf5udoe05O0PbNjsjsPvsjPC/fiEQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIPD/hjuOwUjf+yKeLwRFdoJGLLcN5IZp7AymP4pFRSwFxWexqJ5Y93eBT/4utSqWlF+8Zk8YLokAAA==';
