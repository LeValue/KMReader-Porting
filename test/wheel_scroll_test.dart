import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/ui/scroll_behavior.dart';
import 'package:kmreader/ui/wheel_scroll.dart';

Future<void> wheel(
  WidgetTester tester,
  double delta, {
  Offset at = const Offset(100, 150),
}) => tester.sendEventToBinding(
  PointerScrollEvent(
    kind: PointerDeviceKind.mouse,
    position: at,
    scrollDelta: Offset(0, delta),
  ),
);

Widget fixture(
  ScrollController controller, {
  TargetPlatform platform = TargetPlatform.windows,
  bool reducedMotion = false,
  Widget? child,
}) => MaterialApp(
  scrollBehavior: const AppScrollBehavior(),
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reducedMotion),
    child: Scaffold(
      body:
          child ??
          ListView.builder(
            controller: controller,
            itemExtent: 50,
            itemCount: 200,
            itemBuilder: (_, i) => Text('Row $i'),
          ),
    ),
  ),
);

void main() {
  testWidgets(
    'Windows wheel animates and accumulates without position or velocity jumps',
    (tester) async {
      final controller = AppScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(fixture(controller));
      await wheel(tester, 100);
      expect(
        controller.offset,
        0,
        reason: 'A wheel detent must not jump instantly',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.offset, inExclusiveRange(0, 100));
      final position = controller.position as ScrollPositionWithSingleContext;
      for (var i = 0; i < 5; i++) {
        final before = controller.offset;
        final speed = position.activity!.velocity;
        await wheel(tester, 100);
        expect(controller.offset, before);
        expect(position.activity!.velocity, closeTo(speed, .001));
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.offset, greaterThan(before));
      }
      var previous = controller.offset;
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.offset, inInclusiveRange(previous, 600));
        previous = controller.offset;
      }
      expect(controller.offset, 600);
      expect(controller.position.isScrollingNotifier.value, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('reversing the wheel discards the pending distance immediately', (
    tester,
  ) async {
    final controller = AppScrollController(initialScrollOffset: 700);
    addTearDown(controller.dispose);
    await tester.pumpWidget(fixture(controller));
    await wheel(tester, 500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    final turn = controller.offset;
    await wheel(tester, -100);
    expect(controller.offset, turn);
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      final before = controller.offset;
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.offset, lessThanOrEqualTo(before));
    }
    expect(controller.offset, closeTo(turn - 100, .001));
  });

  testWidgets('high-rate detents keep moving while input is still arriving', (
    tester,
  ) async {
    final controller = AppScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(fixture(controller));
    await wheel(tester, 100);
    await tester.pump();
    for (var frame = 0; frame < 30; frame++) {
      final before = controller.offset;
      // Several events can arrive between display frames. None may restart
      // the ticker or discard the pending distance.
      for (var event = 0; event < 3; event++) {
        await wheel(tester, 20);
        expect(controller.offset, before);
      }
      await tester.pump(const Duration(milliseconds: 8));
      expect(controller.offset, greaterThan(before));
    }
    await tester.pumpAndSettle();
    expect(controller.offset, 1900);
  });

  testWidgets(
    'both Windows wheel boundaries clamp and discard outward backlog',
    (tester) async {
      final controller = AppScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(fixture(controller));
      for (final edge in [0.0, controller.position.maxScrollExtent]) {
        controller.jumpTo(edge);
        await tester.pumpAndSettle();
        final outward = edge == 0 ? -100.0 : 100.0;
        for (var i = 0; i < 10; i++) {
          await wheel(tester, outward);
          await tester.pump(const Duration(milliseconds: 16));
          expect(controller.offset, edge);
          expect(controller.position.isScrollingNotifier.value, isFalse);
        }
        await wheel(tester, -outward);
        await tester.pumpAndSettle();
        expect(controller.offset, edge - outward);
      }
      await wheel(tester, 1000000);
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          controller.offset,
          inInclusiveRange(0, controller.position.maxScrollExtent),
        );
      }
      expect(controller.offset, controller.position.maxScrollExtent);
    },
  );

  for (final scenario in ['Android', 'reduced motion']) {
    testWidgets('$scenario keeps immediate wheel scrolling', (tester) async {
      final controller = AppScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture(
          controller,
          platform: scenario == 'Android'
              ? TargetPlatform.android
              : TargetPlatform.windows,
          reducedMotion: scenario == 'reduced motion',
        ),
      );
      await wheel(tester, 100);
      expect(controller.offset, 100);
      await tester.pumpAndSettle();
      expect(controller.offset, 100);
    });
  }

  testWidgets('jumps, touch and trackpad pan cancel wheel animation', (
    tester,
  ) async {
    final controller = AppScrollController(initialScrollOffset: 400);
    addTearDown(controller.dispose);
    await tester.pumpWidget(fixture(controller));
    for (final input in ['jump', 'touch', 'trackpad']) {
      await wheel(tester, 400);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      if (input == 'jump') {
        controller.jumpTo(200);
      } else if (input == 'touch') {
        final gesture = await tester.startGesture(const Offset(100, 200));
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, 60));
        // Release without a fling.
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
      } else {
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        await gesture.panZoomStart(const Offset(100, 200));
        await gesture.panZoomUpdate(
          const Offset(100, 200),
          pan: const Offset(0, 50),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.panZoomEnd();
      }
      await tester.pumpAndSettle();
      final stopped = controller.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.offset, stopped);
      expect(controller.position.isScrollingNotifier.value, isFalse);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'nested scroll views consume wheel locally and bubble at their edge',
    (tester) async {
      final outer = AppScrollController();
      addTearDown(outer.dispose);
      final innerKey = GlobalKey();
      await tester.pumpWidget(
        fixture(
          outer,
          child: ListView(
            controller: outer,
            children: [
              SizedBox(
                height: 250,
                child: ListView.builder(
                  key: innerKey,
                  itemExtent: 50,
                  itemCount: 20,
                  itemBuilder: (_, i) => Text('Inner $i'),
                ).withWheelScrolling(),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      );
      final inner = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(innerKey),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      await wheel(tester, 100);
      expect(inner.pixels, 0);
      await tester.pumpAndSettle();
      expect(inner.pixels, 100);
      expect(outer.offset, 0);
      inner.jumpTo(inner.maxScrollExtent);
      await tester.pumpAndSettle();
      await wheel(tester, 100);
      await tester.pumpAndSettle();
      expect(inner.pixels, inner.maxScrollExtent);
      expect(outer.offset, 100);
    },
  );

  testWidgets(
    'Shift wheel scrolls the horizontal shelf, ordinary wheel the page',
    (tester) async {
      final outer = AppScrollController();
      addTearDown(outer.dispose);
      final shelfKey = GlobalKey();
      await tester.pumpWidget(
        fixture(
          outer,
          child: ListView(
            controller: outer,
            children: [
              SizedBox(
                height: 250,
                child: ListView.builder(
                  key: shelfKey,
                  scrollDirection: Axis.horizontal,
                  itemExtent: 200,
                  itemCount: 20,
                  itemBuilder: (_, i) => Text('Book $i'),
                ).withWheelScrolling(axis: Axis.horizontal),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      );
      final shelf = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(shelfKey),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await wheel(tester, 100);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(shelf.pixels, 100);
      expect(outer.offset, 0);
      await wheel(tester, 100);
      await tester.pumpAndSettle();
      expect(shelf.pixels, 100);
      expect(outer.offset, 100);
    },
  );

  testWidgets(
    'wheel retargets after resize or content changes and keeps lists lazy',
    (tester) async {
      final controller = AppScrollController();
      addTearDown(controller.dispose);
      var count = 5000;
      var built = 0;
      late StateSetter update;
      await tester.pumpWidget(
        fixture(
          controller,
          child: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return ListView.builder(
                controller: controller,
                itemCount: count,
                itemExtent: 50,
                itemBuilder: (_, i) {
                  built++;
                  return Text('Row $i');
                },
              );
            },
          ),
        ),
      );
      expect(built, lessThan(50));
      await wheel(tester, 800);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      update(() => count = 15);
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent);
      expect(controller.offset, greaterThanOrEqualTo(0));
      await wheel(tester, -100);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
