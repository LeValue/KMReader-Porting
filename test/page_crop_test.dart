import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/features/reader/page_crop.dart';
import 'package:kmreader/features/reader/reader_viewport.dart';

void main() {
  Uint8List pixels(Rect content, {int border = 255}) {
    final data = Uint8List(100 * 100 * 4);
    for (var y = 0; y < 100; y++) {
      for (var x = 0; x < 100; x++) {
        final i = (y * 100 + x) * 4;
        final ink = content.contains(Offset(x.toDouble(), y.toDouble()));
        data.setRange(
          i,
          i + 4,
          ink ? [220, 20, 40, 255] : [border, border, border, 255],
        );
      }
    }
    return data;
  }

  test(
    'border crop matches upstream thresholds and retained-area safeguards',
    () {
      const content = Rect.fromLTRB(8, 8, 92, 92);
      for (final border in [0, 255]) {
        final data = pixels(content, border: border);
        expect(
          cropBounds((data, 100, 100, 'aggressive')),
          const Rect.fromLTRB(.08, .08, .92, .92),
        );
        expect(
          cropBounds((data, 100, 100, 'conservative')),
          const Rect.fromLTRB(.06, .06, .94, .94),
        );
        expect(cropBounds((data, 100, 100, 'disabled')), isNull);
      }
      final small = pixels(const Rect.fromLTRB(25, 25, 75, 75));
      expect(cropBounds((small, 100, 100, 'conservative')), isNull);
      expect(cropBounds((small, 100, 100, 'aggressive')), isNotNull);
      expect(cropBounds((pixels(Rect.zero), 100, 100, 'aggressive')), isNull);
      expect(
        cropBounds((
          pixels(const Rect.fromLTWH(0, 0, 100, 100)),
          100,
          100,
          'aggressive',
        )),
        isNull,
      );
      final settings = const ReaderPreferences(
        borderCrop: 'aggressive',
        doubleTapZoom: 3.5,
      );
      expect(
        ReaderPreferences.fromJson(settings.toJson()).toJson(),
        settings.toJson(),
      );
      expect(
        ReaderPreferences.fromJson({'doubleTapZoom': 100}).doubleTapZoom,
        8,
      );
    },
  );

  testWidgets(
    'cropped pixels align correctly and vertical layout remains bounded',
    (tester) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.white, BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTRB(10, 20, 70, 90),
        Paint()..color = const Color(0xffff0000),
      );
      final picture = recorder.endRecording();
      final bytes = await tester.runAsync(() async {
        final raster = await picture.toImage(100, 100);
        final data = await raster.toByteData(format: ui.ImageByteFormat.png);
        raster.dispose();
        return data!.buffer.asUint8List();
      });
      picture.dispose();
      final crop = await tester.runAsync(() => pageCrop(bytes!, 'aggressive'));
      expect(crop, isNotNull);
      expect(crop!.aspect, closeTo(60 / 70, .04));
      const boundaryKey = ValueKey('crop-pixels');
      Widget content() => PageCropView(
        crop: crop,
        fit: BoxFit.contain,
        child: Image.memory(bytes!, fit: BoxFit.fill),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: crop.aspect * 200,
                height: 200,
                child: content(),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(bytes!),
          tester.element(find.byType(Image)),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      final output = await tester.runAsync(() => boundary.toImage());
      final raw = await tester.runAsync(
        () => output!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      for (final point in [
        const Offset(.1, .1),
        const Offset(.9, .1),
        const Offset(.1, .9),
        const Offset(.9, .9),
      ]) {
        final i =
            ((point.dy * output!.height).floor() * output.width +
                (point.dx * output.width).floor()) *
            4;
        expect(raw!.getUint8(i), 255);
        expect(
          raw.getUint8(i + 1),
          0,
          reason: 'White border must be outside the visible crop',
        );
      }
      output!.dispose();
      await tester.pumpWidget(
        MaterialApp(home: SingleChildScrollView(child: content())),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('configured double tap zoom scale is applied and resets', (
    tester,
  ) async {
    final zoom = TransformationController();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderViewport(
          controller: zoom,
          doubleTapZoom: 3.5,
          startScroll: (_) => null,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    );
    for (final target in [3.5, 1.0]) {
      await tester.tapAt(const Offset(250, 200));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(250, 200));
      await tester.pumpAndSettle();
      expect(zoom.value.getMaxScaleOnAxis(), closeTo(target, .001));
    }
    await tester.pumpWidget(const SizedBox());
    zoom.dispose();
  });
}
