import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/custom_fonts.dart';
import 'package:kmreader/features/reader/epub_document.dart';
import 'package:kmreader/features/reader/epub_host.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/epub_fixture.dart';

void main() {
  final client = HttpClient();
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(client.close);
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('epub-resources-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));
  test('font imports validate, deduplicate and remove local files', () async {
    final store = LocalStore(sqlite3.openInMemory());
    addTearDown(store.close);
    final fonts = CustomFontStore(store, directory);
    final source = File('test/fixtures/DejaVuSerif.ttf');
    final first = await fonts.importFile(XFile(source.path));
    final duplicate = await fonts.importFile(XFile(source.path));
    expect(first['id'], duplicate['id']);
    expect(fonts.fonts, hasLength(1));
    expect(fonts.file(first).existsSync(), true);
    await expectLater(
      fonts.importFile(
        XFile.fromData(
          Uint8List.fromList(utf8.encode('This is not a font.')),
          name: 'fake.ttf',
        ),
      ),
      throwsFormatException,
    );
    await fonts.remove(first['id']);
    expect(fonts.fonts, isEmpty);
    expect(fonts.file(first).existsSync(), false);
  });
  test('IDPF and Adobe font deobfuscation, custom fonts and UTF-16 HTTP encodings', () async {
    const uuid = '550e8400-e29b-41d4-a716-446655440000';
    final original = File('test/fixtures/DejaVuSerif.ttf').readAsBytesSync();
    Uint8List encrypted(List<int> key, int length) {
      final bytes = Uint8List.fromList(original);
      for (var i = 0; i < length; i++) {
        bytes[i] ^= key[i % key.length];
      }
      return bytes;
    }

    final uuidHex = uuid.replaceAll('-', '');
    const chapter =
        '<?xml version="1.0" encoding="UTF-16"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>日本語</title></head><body><p>夜空の星</p></body></html>';
    final utf16 = Uint8List(2 + chapter.codeUnits.length * 2)
      ..[0] = 0xff
      ..[1] = 0xfe;
    final view = ByteData.sublistView(utf16);
    for (var i = 0; i < chapter.codeUnits.length; i++) {
      view.setUint16(2 + i * 2, chapter.codeUnitAt(i), Endian.little);
    }
    final file = fixture(
      directory,
      resources: {
        'OPS/one.xhtml': utf16,
        'OPS/idpf.ttf': encrypted(
          sha1.convert(utf8.encode('urn:uuid:$uuid')).bytes,
          1040,
        ),
        'OPS/adobe.ttf': encrypted([
          for (var i = 0; i < uuidHex.length; i += 2)
            int.parse(uuidHex.substring(i, i + 2), radix: 16),
        ], 1024),
        'META-INF/encryption.xml': utf8.encode(
          '<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><CipherData><CipherReference URI="OPS/idpf.ttf"/></CipherData></EncryptedData><EncryptedData><EncryptionMethod Algorithm="http://ns.adobe.com/pdf/enc#RC"/><CipherData><CipherReference URI="OPS/adobe.ttf"/></CipherData></EncryptedData></encryption>',
        ),
      },
    );
    final document = EpubDocument.open(file.path);
    final host = await EpubHost.open(document, filePath: file.path);
    addTearDown(() async {
      await host.close();
      document.close();
    });
    expect(document.chapter(0), contains('夜空の星'));
    for (final name in ['idpf.ttf', 'adobe.ttf']) {
      final response = await (await client.getUrl(
        host.base.resolve('book/OPS/$name'),
      )).close();
      expect(response.statusCode, 200);
      expect(
        await response.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
        original,
      );
    }
    final page = await (await client.getUrl(
      host.base.resolve('book/OPS/one.xhtml'),
    )).close();
    expect(page.headers.contentType!.charset, 'utf-16le');
    await page.drain<void>();
    final url = await host.addFont(
      sha256.convert(original).toString(),
      original,
    );
    final font = await (await client.getUrl(url)).close();
    expect(font.headers.contentType!.mimeType, 'font/ttf');
    expect(
      await font.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
      original,
    );
  });
}
