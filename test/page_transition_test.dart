import 'support/comic_spread_check.dart';

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/page_transition.dart';
import 'package:kmreader/features/reader/comic_spread.dart';

void main() {
  test('unequal spread formats retain the same screen spine', () {
    for (final aspects in [
      [.5, .75],
      [1.4, .6],
      [.6, 1.4],
    ]) {
      final leaves = comicLeafBounds(const Size(800, 500), aspects);
      expect(leaves.first.right, 400);
      expect(leaves.last.left, 400);
    }
  });
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

  testWidgets('page boundary rejects taps and drags before capturing a frame', (
    tester,
  ) async {
    final key = GlobalKey<ReaderPageTransitionState>();
    var captures = 0, moves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPageTransition(
          key: key,
          canTurn: (_) => false,
          captureImage: () async {
            captures++;
            return null;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    await key.currentState!.turn('curl', 1, () async {
      moves++;
    });
    final drag = key.currentState!.drag(
      reverse: false,
      width: 300,
      preview: (_) async {
        moves++;
        return true;
      },
      finish: (_, _) async {
        moves++;
      },
    );
    drag.update(
      DragUpdateDetails(delta: Offset(-150, 0), globalPosition: Offset(10, 50)),
    );
    drag.end(DragEndDetails());
    await tester.pumpAndSettle();
    expect(captures, 0);
    expect(moves, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'prepared comic turns start without a screen capture or early navigation',
    (tester) async {
      final before = (await tester.runAsync(() => raster(Colors.red)))!;
      final after = (await tester.runAsync(() => raster(Colors.green)))!;
      addTearDown(before.dispose);
      addTearDown(after.dispose);
      final key = GlobalKey<ReaderPageTransitionState>();
      var captures = 0, moves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageTransition(
            key: key,
            prepare: (_) => PreparedPageTurn(
              before.clone(),
              after.clone(),
              const Rect.fromLTWH(0, 0, 100, 100),
              null,
            ),
            captureImage: () async {
              captures++;
              return null;
            },
            child: const SizedBox.expand(),
          ),
        ),
      );
      final work = key.currentState!.turn('curl', 1, () async {
        moves++;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(captures, 0);
      expect(moves, 0);
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<PageTurnPainter>()
          .single;
      expect(painter.progress, greaterThan(0));
      await tester.pumpAndSettle();
      await work;
      expect(moves, 1);
      expect(captures, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  verifyComicSpread();
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
      final unrevealed = (100 * 200 + 20) * 4;
      final revealed = (100 * 200 + 180) * 4;
      expect(
        data.getUint8(unrevealed + 1),
        0,
        reason:
            'Margins ahead of the fold must retain their original background',
      );
      expect(
        data.getUint8(revealed + 1),
        greaterThan(100),
        reason: 'Margins behind the fold must reveal the next page',
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
