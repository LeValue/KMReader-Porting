import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/page_transition.dart';

void verifyComicSpread() {
  testWidgets('double-page curl shows the incoming opposite leaf on its back', (
    tester,
  ) async {
    Future<ui.Image> spread(Color left, Color right) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 100, 200),
        Paint()..color = left,
      );
      canvas.drawRect(
        const Rect.fromLTWH(100, 0, 100, 200),
        Paint()..color = right,
      );
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(200, 200);
      } finally {
        picture.dispose();
      }
    }

    final before = (await tester.runAsync(
      () => spread(Colors.blue, Colors.red),
    ))!;
    final after = (await tester.runAsync(
      () => spread(Colors.green, Colors.yellow),
    ))!;
    addTearDown(before.dispose);
    addTearDown(after.dispose);
    for (final direction in [1, -1]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 200,
                height: 200,
                child: CustomPaint(
                  painter: PageTurnPainter(
                    before,
                    after,
                    .75,
                    'curl',
                    direction,
                    sheetBounds: Rect.fromLTWH(
                      direction > 0 ? 100 : 0,
                      0,
                      100,
                      200,
                    ),
                    backBounds: Rect.fromLTWH(
                      direction > 0 ? 0 : 100,
                      0,
                      100,
                      200,
                    ),
                    foldSlope: .15,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final data = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      if (Platform.environment['KMREADER_SAVE_COMIC_FRAMES'] == '1') {
        final folder = Directory('artifacts/comic-motion-0.8.7')
          ..createSync(recursive: true);
        final png = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        ))!;
        File(
          '${folder.path}/spread-${direction > 0 ? 'forward' : 'backward'}.png',
        ).writeAsBytesSync(png.buffer.asUint8List());
      }
      image.dispose();
      var backPixels = 0, blackPixels = 0;
      for (var i = 0; i < data.lengthInBytes; i += 4) {
        final red = data.getUint8(i),
            green = data.getUint8(i + 1),
            blue = data.getUint8(i + 2);
        if (direction > 0
            ? green > red * 1.5 && green > blue * 1.5
            : red > 150 && green > 150 && blue < 80) {
          backPixels++;
        }
        if (red < 35 && green < 35 && blue < 35) blackPixels++;
      }
      expect(
        backPixels,
        greaterThan(1500),
        reason: 'The incoming back must use the opposite leaf',
      );
      expect(
        blackPixels,
        lessThan(1000),
        reason: 'An intersecting outline must never fill a black curtain',
      );
    }
    await tester.pumpWidget(const SizedBox());
  });
}
