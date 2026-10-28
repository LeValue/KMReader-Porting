import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/reader_ocr.dart';

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
