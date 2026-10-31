import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/page_transition.dart';

void main() {
  Future<ui.Image> raster(Color color) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(color, BlendMode.src);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(100, 100);
    } finally {
      picture.dispose();
    }
  }

  testWidgets(
    'comic curl bends the artwork without lifting its black letterbox',
    (tester) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(Colors.black, BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(50, 0, 100, 200),
        Paint()..color = Colors.red,
      );
      final picture = recorder.endRecording();
      final before = (await tester.runAsync(() => picture.toImage(200, 200)))!;
      picture.dispose();
      final after = (await tester.runAsync(() => raster(Colors.green)))!;
      addTearDown(before.dispose);
      addTearDown(after.dispose);
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
                    .25,
                    'curl',
                    1,
                    sheetBounds: const Rect.fromLTWH(50, 0, 100, 200),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final data = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      image.dispose();
      final offset = (100 * 200 + 20) * 4;
      expect(
        data.getUint8(offset + 1),
        greaterThan(100),
        reason: 'Black margins must stay off the curled sheet',
      );
    },
  );
  testWidgets('page effects preserve the first and final rendered pages', (
    tester,
  ) async {
    final before = (await tester.runAsync(
      () => raster(const Color(0xffff0000)),
    ))!;
    final after = (await tester.runAsync(
      () => raster(const Color(0xff00ff00)),
    ))!;
    addTearDown(before.dispose);
    addTearDown(after.dispose);
    const key = ValueKey('pixels');
    for (final style in ['slide', 'cover', 'curl']) {
      for (final direction in [-1, 1]) {
        for (final progress in [0.0, 1.0]) {
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: RepaintBoundary(
                  key: key,
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: CustomPaint(
                      painter: PageTurnPainter(
                        before,
                        after,
                        progress,
                        style,
                        direction,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(key),
          );
          final frame = await tester.runAsync(() => boundary.toImage());
          final pixels = await tester.runAsync(
            () => frame!.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          final i = (50 * 100 + 50) * 4;
          expect(
            pixels!.getUint8(i),
            progress == 0 ? 255 : 0,
            reason: '$style direction $direction at $progress',
          );
          expect(pixels.getUint8(i + 1), progress == 0 ? 0 : 255);
          frame!.dispose();
        }
      }
    }
  });
  testWidgets(
    'unavailable screenshots never block navigation or leak after close',
    (tester) async {
      final key = GlobalKey<ReaderPageTransitionState>();
      var moved = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageTransition(
            key: key,
            capture: () async => throw PlatformException(code: 'unavailable'),
            child: const SizedBox.expand(),
          ),
        ),
      );
      final turn = key.currentState!.turn('curl', 1, () async {
        moved++;
      });
      await tester.pumpAndSettle();
      await turn;
      expect(moved, 1);
      expect(tester.takeException(), isNull);
      final capture = Completer<Uint8List?>();
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageTransition(
            key: key,
            capture: () => capture.future,
            child: const SizedBox.expand(),
          ),
        ),
      );
      final canceled = key.currentState!.turn('cover', 1, () async {
        moved++;
      });
      await tester.pumpWidget(const SizedBox());
      capture.complete(null);
      await canceled;
      expect(moved, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
