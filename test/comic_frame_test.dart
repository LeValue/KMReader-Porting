import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/comic_frames.dart';

void main() {
  for (final size in [
    const Size(600, 900),
    const Size(360, 720),
    const Size(840, 600),
  ]) {
    testWidgets('prepared comic equals live artwork at DPR 3 for $size', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bytes = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
        for (var x = 0.0; x < size.width; x += 4) {
          canvas.drawRect(
            Rect.fromLTWH(x, 0, 2, size.height),
            Paint()..color = Colors.black,
          );
        }
        canvas.drawRect(
          Rect.fromLTWH(20, 20, 40, 40),
          Paint()..color = Colors.red,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        picture.dispose();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      }))!;
      final key = GlobalKey();
      var ready = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.black,
              child: Image.memory(
                bytes,
                width: double.infinity,
                fit: BoxFit.contain,
                cacheWidth: 600,
                frameBuilder: (_, child, frame, sync) {
                  ready = frame != null || sync;
                  return child;
                },
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 100 && !ready; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(ready, true);
      await tester.pump();
      final frames = ComicFrames();
      addTearDown(frames.close);
      await tester.runAsync(
        () => frames.warm(
          key: 'page',
          size: const Size(200, 400),
          pixelRatio: 3,
          first: 1,
          count: 1,
          pageCount: 1,
          rtl: false,
          background: Colors.black,
          load: (_) async => bytes,
        ),
      );
      final frame = frames.borrow('page')!;
      addTearDown(frame.image.dispose);
      expect(frame.image.width, 600);
      expect(frame.image.height, 1200);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final live = (await tester.runAsync(
        () => boundary.toImage(pixelRatio: 3),
      ))!;
      final pixels = (await tester.runAsync(
        () => live.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      live.dispose();
      final prepared = (await tester.runAsync(
        () => frame.image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final a = pixels.buffer.asUint8List(), b = prepared.buffer.asUint8List();
      expect(a.length, b.length);
      var error = 0;
      for (var i = 0; i < a.length; i++) {
        error += (a[i] - b[i]).abs();
      }
      expect(
        error / a.length,
        lessThan(.1),
        reason: 'Starting curl must retain live resolution and image fit',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
