import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/page_transition.dart';

void verifyNativeComicSheets() {
  testWidgets(
    'native comic curl leaves letterbox pixels outside the paper mesh',
    (tester) async {
      Future<ui.Image> raster(bool paper) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawColor(paper ? Colors.black : Colors.green, BlendMode.src);
        if (paper) {
          canvas.drawRect(
            const Rect.fromLTWH(40, 0, 120, 240),
            Paint()..color = Colors.white,
          );
          for (var y = 15.0; y < 240; y += 20) {
            canvas.drawRect(
              Rect.fromLTWH(50, y, 100, 3),
              Paint()..color = Colors.red,
            );
          }
        }
        final picture = recorder.endRecording();
        try {
          return await picture.toImage(200, 240);
        } finally {
          picture.dispose();
        }
      }

      final before = (await tester.runAsync(() => raster(true)))!,
          after = (await tester.runAsync(() => raster(false)))!;
      final key = GlobalKey();
      try {
        for (final direction in [-1, 1]) {
          for (final progress in [.01, .25, .6, .99]) {
            await tester.pumpWidget(
              MaterialApp(
                home: Center(
                  child: RepaintBoundary(
                    key: key,
                    child: SizedBox(
                      width: 200,
                      height: 240,
                      child: CustomPaint(
                        painter: PageTurnPainter(
                          before,
                          after,
                          progress,
                          'curl',
                          direction,
                          sheetBounds: const Rect.fromLTWH(40, 0, 120, 240),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = (await tester.runAsync(
              () => boundary.toImage(pixelRatio: 1),
            ))!;
            final pixels = await tester.runAsync(
              () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
            );
            image.dispose();
            for (final x in [10, 190]) {
              final offset = (120 * 200 + x) * 4;
              final values = [
                for (var i = 0; i < 3; i++) pixels!.getUint8(offset + i),
              ];
              expect(
                values.any((v) => v > 80),
                true,
                reason:
                    'Black letterbox lifted: direction=$direction p=$progress x=$x',
              );
            }
          }
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        before.dispose();
        after.dispose();
      }
    },
  );
}
