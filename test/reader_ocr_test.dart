import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/reader_ocr.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.levalue.kmreader/ocr');
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('reader-ocr-'));
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    directory.deleteSync(recursive: true);
  });
  test('OCR returns bounded regions, caches by image/language, and removes temporary source files', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'capabilities') {
            return {
              'languages': ['latin', 'ja'],
              'offline': true,
            };
          }
          calls++;
          final args = Map<String, dynamic>.from(call.arguments as Map);
          expect(File(args['path']).readAsBytesSync(), [1, 2, 3]);
          return {
            'width': 100,
            'height': 200,
            'text': 'Hello',
            'blocks': [
              {'text': 'Hello', 'x': -10, 'y': 20, 'width': 120, 'height': 60},
              {'text': 'Invalid', 'x': 0, 'y': 0, 'width': -1, 'height': 20},
            ],
          };
        });
    final reader = ReaderOcr(directory);
    expect(await reader.languages(), ['latin', 'ja']);
    final bytes = Uint8List.fromList([1, 2, 3]);
    final result = await reader.recognize(bytes, 'latin');
    expect(result.text, 'Hello');
    expect(result.blocks, hasLength(1));
    expect(result.blocks.single.bounds, const Rect.fromLTRB(0, .1, 1, .4));
    await reader.recognize(bytes, 'latin');
    expect(calls, 1);
    await reader.recognize(bytes, 'ja');
    expect(calls, 2);
    await reader.recognize(bytes, 'latin', cache: false);
    expect(calls, 3);
    expect(
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path)
          .any((p) => p.endsWith('.image')),
      false,
    );
    expect(
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json')),
      hasLength(2),
    );
  });
  test('repository shutdown drains OCR and prevents cache writes after account removal', () async {
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'account',
      name: 'Fixture',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    final repository = Repository(
      profile: profile,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: '',
      ),
      store: store,
      directory: directory,
    );
    final entered = Completer<void>(),
        reply = Completer<Map<String, dynamic>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          entered.complete();
          return reply.future;
        });
    try {
      final work = repository.ocr.recognize(
        Uint8List.fromList([1, 2, 3]),
        'latin',
      );
      await entered.future;
      var drained = false;
      final closing = repository.stopDownloadWork().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, false);
      await expectLater(
        repository.ocr.recognize(Uint8List.fromList([1]), 'latin'),
        throwsFormatException,
      );
      reply.complete({
        'width': 100,
        'height': 200,
        'text': 'Synthetic private text',
        'blocks': [],
      });
      expect((await work).text, 'Synthetic private text');
      await closing;
      expect(drained, true);
      expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
      store.removeServer(profile.id);
      final account = Directory('${directory.path}/${profile.id}');
      await account.delete(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await account.exists(), false);
    } finally {
      await repository.stopDownloadWork();
      store.close();
    }
  });
  test('concurrent OCR results use independent temporary files and leave one valid cache', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return {'width': 100, 'height': 200, 'text': 'Result', 'blocks': []};
        });
    final reader = ReaderOcr(directory), bytes = Uint8List.fromList([1, 2, 3]);
    final results = await Future.wait([
      reader.recognize(bytes, 'latin'),
      reader.recognize(bytes, 'latin'),
    ]);
    await reader.settled;
    expect(results.map((r) => r.text), ['Result', 'Result']);
    expect(calls, 2);
    final files = directory
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    expect(files, hasLength(1));
    expect(jsonDecode(files.single.readAsStringSync())['text'], 'Result');
    reader.close();
  });
  test('failed recognition leaves no image or cached private text', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => throw PlatformException(code: 'unavailable'),
        );
    await expectLater(
      ReaderOcr(directory).recognize(
        Uint8List.fromList(utf8.encode('source')),
        'latin',
        cache: false,
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
    expect(
      () => OcrDocument.parse({'width': 0, 'height': 20}),
      throwsFormatException,
    );
  });
}
