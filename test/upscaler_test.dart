import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/page_upscaler.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('upscale decisions match source screen-fit threshold and reject invalid dimensions', () {
    expect(PageUpscaler.shouldEnhance(800, 1200, 1080, 1920, 1.05), true);
    expect(PageUpscaler.shouldEnhance(1600, 2400, 1080, 1920, 1.05), false);
    expect(PageUpscaler.shouldEnhance(0, 1200, 1080, 1920, 1.05), false);
    expect(
      PageUpscaler.shouldEnhance(100, 100, double.infinity, 200, 1.05),
      false,
    );
  });
  test('portable model matches source-network pixels and the isolate pipeline caches its output', () async {
    final source = File('test/fixtures/upscale-source.rgba').readAsBytesSync(),
        expected = File('test/fixtures/upscale-expected.rgba')
            .readAsBytesSync();
    final model = await rootBundle.load(PageUpscaler.modelAsset);
    OrtEnv.instance.init();
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(2)
      ..setInterOpNumThreads(1);
    final session = OrtSession.fromBuffer(
      model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes),
      options,
    );
    try {
      final actual = upscalePixels(session, source, 22, 24);
      expect(actual.length, expected.length);
      var worst = 0;
      for (var i = 0; i < actual.length; i++) {
        final difference = (actual[i] - expected[i]).abs();
        if (difference > worst) worst = difference;
      }
      expect(worst, lessThanOrEqualTo(1));
    } finally {
      session.release();
      options.release();
      OrtEnv.instance.release();
    }
    final directory = Directory.systemTemp.createTempSync('upscaler-');
    final manager = PageUpscaler(directory);
    try {
      final ready = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        source,
        22,
        24,
        ui.PixelFormat.rgba8888,
        ready.complete,
      );
      final image = await ready.future;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final bytes = data!.buffer.asUint8List();
      final enhanced = await manager.enhance(bytes, const ui.Size(100, 100));
      expect(enhanced, isNotNull, reason: manager.error);
      final codec = await ui.instantiateImageCodec(enhanced!);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 44);
      expect(frame.image.height, 48);
      frame.image.dispose();
      codec.dispose();
      final cached = await manager.enhance(bytes, const ui.Size(100, 100));
      expect(cached, enhanced);
      expect(
        directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.png')),
        hasLength(1),
      );
    } finally {
      manager.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      directory.deleteSync(recursive: true);
    }
  }, skip: Platform.environment['KMREADER_ONNX_TEST'] != '1');
}
