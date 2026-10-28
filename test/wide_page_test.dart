import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/reader_viewport.dart';
import 'package:kmreader/features/reader/wide_page.dart';

void main() {
  for (final rtl in [false, true]) {
    testWidgets(
      'wide-page offset restores through rotation without recording navigation; RTL=$rtl',
      (tester) async {
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var writes = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WidePage(
                aspect: 2,
                rtl: rtl,
                initialFraction: .5,
                onPanSettled: (_) => writes++,
                startPageScroll: (_) => null,
                child: const ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
            .controller!;
        expect(controller.offset, closeTo(400, 1));
        expect(writes, 0);
        tester.view.physicalSize = const Size(1000, 400);
        await tester.pumpAndSettle();
        expect(controller.position.maxScrollExtent, 0);
        expect(writes, 0);
        tester.view.physicalSize = const Size(400, 600);
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(400, 1));
        expect(writes, 0);
        await tester.timedDrag(
          find.byType(WidePage),
          Offset(rtl ? 100 : -100, 0),
          const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        expect(writes, 1);
        expect(controller.offset, greaterThan(450));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    testWidgets(
      'wide-page panning owns its gesture and turns only from the edge; RTL=$rtl',
      (tester) async {
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pages = PageController(), zoom = TransformationController();
        var current = 0, original = 0, controls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderViewport(
                controller: zoom,
                onContact: () => original = (pages.page ?? 0).round(),
                onPinch: () => pages.jumpToPage(original),
                startScroll: (details) => pages.position.drag(details, () {}),
                child: PageView.builder(
                  controller: pages,
                  reverse: rtl,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 2,
                  onPageChanged: (page) => current = page,
                  itemBuilder: (_, page) => page == 0
                      ? WidePage(
                          aspect: 2,
                          rtl: rtl,
                          startPageScroll: (details) =>
                              pages.position.drag(details, () {}),
                          onControls: () => controls++,
                          child: Row(
                            children: [
                              for (final color in [
                                Colors.red,
                                Colors.blue,
                                Colors.green,
                              ])
                                Expanded(child: ColoredBox(color: color)),
                            ],
                          ),
                        )
                      : const ColoredBox(color: Colors.amber),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final wide = find.byType(WidePage);
        final scroll = tester
            .widget<SingleChildScrollView>(
              find.descendant(
                of: wide,
                matching: find.byType(SingleChildScrollView),
              ),
            )
            .controller!;
        expect(scroll.position.maxScrollExtent, 800);
        await tester.timedDrag(
          wide,
          Offset(rtl ? 180 : -180, 0),
          const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        expect(scroll.offset, greaterThan(100));
        expect(current, 0);

        // A late second finger cancels content dragging before becoming a pinch.
        scroll.jumpTo(300);
        await tester.pump();
        final first = await tester.startGesture(
          const Offset(280, 300),
          pointer: 1,
        );
        await first.moveBy(Offset(rtl ? 60 : -60, 0));
        await tester.pump();
        final second = await tester.startGesture(
          const Offset(100, 300),
          pointer: 2,
        );
        await tester.pump();
        await first.moveTo(const Offset(340, 300));
        await second.moveTo(const Offset(40, 300));
        await tester.pump();
        await first.up();
        await second.up();
        await tester.pumpAndSettle();
        expect(current, 0);
        expect(scroll.offset, closeTo(300, 1));
        final viewport = tester.widget<ReaderViewport>(
          find
              .descendant(of: wide, matching: find.byType(ReaderViewport))
              .first,
        );
        expect(
          viewport.controller.value.getMaxScaleOnAxis(),
          greaterThan(1.05),
        );
        await tester.tap(wide);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(controls, 1);

        viewport.controller.value = Matrix4.identity();
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump();
        await tester.drag(wide, Offset(rtl ? 300 : -300, 0));
        await tester.pumpAndSettle();
        expect(current, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        pages.dispose();
        zoom.dispose();
      },
    );
  }
}
