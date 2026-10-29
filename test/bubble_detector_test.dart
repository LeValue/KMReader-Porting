import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/bubble_detector.dart';
import 'package:kmreader/features/reader/reader_ocr.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bubble boxes suppress duplicates, clip edges and reject invalid outputs',
    () {
      const columns = 6;
      final data = Float32List(columns * 5);
      void box(
        int index,
        double x,
        double y,
        double w,
        double h,
        double score,
      ) {
        for (final (row, value) in [x, y, w, h, score].indexed) {
          data[row * columns + index] = value;
        }
      }

      box(0, 320, 320, 100, 100, .9);
      box(1, 322, 322, 100, 100, .8);
      box(2, 620, 620, 100, 100, .85);
      box(3, 100, 100, 50, 50, .29);
      box(4, double.nan, 100, 50, 50, .95);
      box(5, 100, 100, -50, 50, .99);
      final result = decodeBubbleBoxes(data, columns: columns);
      expect(result.boxes, hasLength(2));
      expect(result.maxScore, closeTo(.99, 1e-6));
      expect(result.boxes.first.bounds.center.dx, closeTo(.5, 1e-6));
      expect(result.boxes.last.bounds.right, 1);
      expect(result.boxes.last.bounds.bottom, 1);
      expect(
        () => decodeBubbleBoxes(Float32List(5), columns: 2),
        throwsFormatException,
      );
    },
  );
  test('bubble grouping keeps every text block once, including narration outside bubbles', () {
    final caption = OcrBlock('Caption', const ui.Rect.fromLTWH(.7, .8, .2, .1));
    final document = OcrDocument(100, 200, 'Hello\nCaption\nworld', [
      OcrBlock('Hello', const ui.Rect.fromLTWH(.1, .1, .2, .1)),
      caption,
      OcrBlock('world', const ui.Rect.fromLTWH(.1, .25, .2, .1)),
    ]);
    const bubble = BubbleBox(ui.Rect.fromLTWH(.05, .05, .4, .4), .9);
    final grouped = groupOcrBubbles(document, [bubble]);
    expect(grouped.blocks, hasLength(2));
    expect(grouped.blocks.first.text, 'Hello\nworld');
    expect(grouped.blocks.first.bounds, bubble.bounds);
    expect(identical(grouped.blocks.last, caption), true);
    expect(grouped.text, 'Hello\nworld\n\nCaption');
    expect(identical(groupOcrBubbles(document, []), document), true);
  });
  test('overlapping bubble groups assign a text block to its tightest overlap once', () {
    final document = OcrDocument(100, 200, 'Text', [
      OcrBlock('Text', const ui.Rect.fromLTWH(.2, .2, .1, .1)),
    ]);
    final result = groupOcrBubbles(document, const [
      BubbleBox(ui.Rect.fromLTWH(.25, .2, .2, .2), .9),
      BubbleBox(ui.Rect.fromLTWH(.1, .1, .3, .3), .8),
    ]);
    expect(result.blocks, hasLength(1));
    expect(result.blocks.single.text, 'Text');
    expect(result.blocks.single.bounds, const ui.Rect.fromLTWH(.1, .1, .3, .3));
  });
  test(
    'closing detection during preprocessing drains it and rejects new work',
    () async {
      final detector = BubbleDetector();
      final pixel = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([255, 255, 255, 255]),
        1,
        1,
        ui.PixelFormat.rgba8888,
        pixel.complete,
      );
      final image = await pixel.future;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final work = detector.detect(png!.buffer.asUint8List(), cache: false);
      final stopped = detector.close();
      await expectLater(work, throwsStateError);
      await stopped;
      await expectLater(
        detector.detect(png.buffer.asUint8List()),
        throwsStateError,
      );
    },
  );
  test('portable bubble model matches the source MIL network and runs in an isolated worker', () async {
    final fixture = jsonDecode(
      await rootBundle.loadString('assets/models/bubble_detector.json'),
    ) as Map;
    final model = await rootBundle.load(BubbleDetector.modelAsset);
    OrtEnv.instance.init();
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(2)
      ..setInterOpNumThreads(1);
    final session = OrtSession.fromBuffer(
      model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes),
      options,
    );
    final rgba = Uint8List(640 * 640 * 4);
    try {
      for (final kind in ['white', 'checkerboard']) {
        for (var y = 0; y < 640; y++) {
          for (var x = 0; x < 640; x++) {
            final value = kind == 'white' ? 255 : ((x + y) ~/ 16 % 2) * 255;
            final offset = (y * 640 + x) * 4;
            rgba[offset] = value;
            rgba[offset + 1] = value;
            rgba[offset + 2] = value;
            rgba[offset + 3] = 255;
          }
        }
        final expected = fixture['validation'][kind] as Map;
        final actual = predictBubblePixels(session, rgba);
        for (var row = 0; row < 5; row++) {
          final columns = expected['columns'] as List;
          for (var i = 0; i < columns.length; i++) {
            expect(
              actual[row * 8400 + (columns[i] as int)],
              closeTo(
                expected['expected'][row][i] as num,
                row == 4 ? 2e-5 : .03,
              ),
            );
          }
        }
        expect(
          decodeBubbleBoxes(actual).maxScore,
          closeTo(expected['maxScore'] as num, 2e-5),
        );
      }
    } finally {
      session.release();
      options.release();
      OrtEnv.instance.release();
    }
    final ready = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList(List.filled(16 * 16 * 4, 255)),
      16,
      16,
      ui.PixelFormat.rgba8888,
      ready.complete,
    );
    final image = await ready.future;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final detector = BubbleDetector();
    try {
      final detected = await detector.detect(png!.buffer.asUint8List());
      expect(detected.boxes, isEmpty);
      expect(
        detected.maxScore,
        closeTo(fixture['validation']['white']['maxScore'] as num, 2e-5),
      );
      expect(
        identical(await detector.detect(png.buffer.asUint8List()), detected),
        true,
      );
    } finally {
      await detector.close();
    }
  }, skip: Platform.environment['KMREADER_ONNX_TEST'] != '1');
}
