import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/ui/scroll_behavior.dart';
import 'package:kmreader/ui/wheel_scroll.dart';

void verifyNativeWindowsWheel() {
  if (!Platform.isWindows) return;
  testWidgets(
    'Win32 wheel input animates continuously, reverses and stays at both edges',
    (tester) async {
      final controller = AppScrollController();
      final propagateDeviceInput =
          tester.binding.shouldPropagateDevicePointerEvents;
      final boundary = GlobalKey();
      final deltas = <double>[], starts = <double>[];
      Future<String> pixels() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          return sha256
              .convert(
                data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
              )
              .toString();
        } finally {
          image.dispose();
        }
      }

      Future<void> nativeWheel(int amount) async {
        final expectedCount = deltas.length + 1;
        await const MethodChannel('dev.levalue.kmreader/reader_display')
            .invokeMethod<void>('testMouseWheel', {
              'x': 100.0 * tester.view.devicePixelRatio,
              'y': 150.0 * tester.view.devicePixelRatio,
              'delta': amount,
            });
        for (
          var frame = 0;
          frame < 30 && deltas.length < expectedCount;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          deltas.length,
          expectedCount,
          reason: 'The Win32 message must reach Flutter',
        );
      }

      try {
        // Flutter tests normally discard engine/device events. This check
        // intentionally enters through Win32, so opt in only for its lifetime.
        tester.binding.shouldPropagateDevicePointerEvents = true;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: false),
              child: child!,
            ),
            scrollBehavior: const AppScrollBehavior().copyWith(
              scrollbars: false,
            ),
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      starts.add(controller.offset);
                      deltas.add(event.scrollDelta.dy);
                    }
                  },
                  child: ListView.builder(
                    controller: controller,
                    itemExtent: 52,
                    itemCount: 140,
                    itemBuilder: (_, i) => Text('Native wheel row $i'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await nativeWheel(-120);
        final step = deltas.single;
        expect(step, greaterThan(0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.offset, inExclusiveRange(0, step));
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(step, .01));

        for (var i = 0; i < 4; i++) {
          await nativeWheel(-120);
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(controller.offset, inExclusiveRange(step, step * 5));
        await nativeWheel(120);
        final reversedTarget = (starts.last + deltas.last).clamp(
          0.0,
          controller.position.maxScrollExtent,
        );
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(reversedTarget, .01));

        for (final edge in [0.0, controller.position.maxScrollExtent]) {
          controller.jumpTo(edge);
          await tester.pumpAndSettle();
          final baseline = await pixels();
          for (var i = 0; i < 8; i++) {
            await nativeWheel(edge == 0 ? 120 : -120);
            for (var frame = 0; frame < 2; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(controller.offset, edge);
              expect(await pixels(), baseline);
            }
          }
        }
        expect(controller.position.isScrollingNotifier.value, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding.shouldPropagateDevicePointerEvents =
            propagateDeviceInput;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        controller.dispose();
      }
    },
  );
}
