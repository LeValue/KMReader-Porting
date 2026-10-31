import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/page_motion.dart';
import 'package:kmreader/features/reader/cover_page.dart';

void main() {
  test(
    'existing reader animation choices migrate while new defaults use cover',
    () {
      expect(ReaderPreferences.fromJson({}).transition, 'cover');
      expect(ReaderPreferences.fromJson({'animate': true}).transition, 'slide');
      final prefs = const ReaderPreferences().copy(
        transition: 'slide',
        animate: false,
      );
      final restored = ReaderPreferences.fromJson(prefs.toJson());
      expect(restored.transition, 'slide');
      expect(restored.animate, false);
    },
  );
  for (final rtl in [false, true]) {
    testWidgets(
      'cover motion keeps outgoing artwork stationary while revealing the next page; RTL=$rtl',
      (tester) async {
        tester.view.physicalSize = const Size(200, 200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pages = PageController();
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: key,
              child: PageView.builder(
                controller: pages,
                pageSnapping: false,
                reverse: rtl,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 2,
                itemBuilder: (_, index) => CoverPage(
                  controller: pages,
                  motion: const PageMotion(tint: 0, cornerRadius: 0),
                  index: index,
                  reverse: rtl,
                  background: Colors.white,
                  child: index == 0
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: ColoredBox(color: Colors.red)),
                            Expanded(child: ColoredBox(color: Colors.green)),
                          ],
                        )
                      : const ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<List<int>> pixel(int x) async =>
            (await tester.runAsync(() async {
              final boundary =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final bytes = data!.buffer.asUint8List();
              final value = bytes.sublist(
                (100 * image.width + x) * 4,
                (100 * image.width + x) * 4 + 4,
              );
              image.dispose();
              return value;
            }))!;
        pages.position.jumpTo(50);
        await tester.pumpAndSettle();
        expect(
          await pixel(rtl ? 125 : 75),
          rtl ? [76, 175, 80, 255] : [244, 67, 54, 255],
        );
        expect(await pixel(rtl ? 15 : 185), [33, 150, 243, 255]);
        pages.jumpToPage(1);
        await tester.pumpAndSettle();
        expect(await pixel(100), [33, 150, 243, 255]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        pages.dispose();
      },
    );
  }
}
