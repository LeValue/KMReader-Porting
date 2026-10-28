import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/reader_display.dart';

void main() {
  testWidgets(
    'a reader hidden behind the application lock releases its screen-awake request',
    (tester) async {
      final awake = <bool>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReaderDisplay.channel, (call) async {
        if (call.method == 'setKeepAwake') awake.add(call.arguments as bool);
        return <String, int>{};
      });
      Widget screen(bool visible) => MaterialApp(
        home: TickerMode(
          enabled: visible,
          child: const ReaderDisplay(keepAwake: true, child: Text('Reader')),
        ),
      );
      try {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(screen(true));
        await tester.pumpAndSettle();
        expect(awake, [true]);
        await tester.pumpWidget(screen(false));
        await tester.pumpAndSettle();
        expect(awake, [true, false]);
        await tester.pumpWidget(screen(true));
        await tester.pumpAndSettle();
        expect(awake, [true, false, true]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(awake, [true, false, true, false]);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        messenger.setMockMethodCallHandler(ReaderDisplay.channel, null);
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
  testWidgets(
    'screen-awake ownership survives nested readers and releases on background/last close',
    (tester) async {
      final awake = <bool>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReaderDisplay.channel, (call) async {
        if (call.method == 'setKeepAwake') awake.add(call.arguments as bool);
        return <String, int>{};
      });
      Widget screen({bool outer = true, bool inner = true}) => MaterialApp(
        home: ReaderDisplay(
          key: const ValueKey('outer'),
          keepAwake: outer,
          child: inner
              ? const ReaderDisplay(
                  key: ValueKey('inner'),
                  keepAwake: true,
                  child: Text('Reader'),
                )
              : const Text('Reader'),
        ),
      );
      try {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(awake, [true]);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(awake, [true, false]);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(awake, [true, false, true]);
        await tester.pumpWidget(screen(outer: false));
        await tester.pumpAndSettle();
        expect(awake, [true, false, true]);
        await tester.pumpWidget(screen(outer: false, inner: false));
        await tester.pumpAndSettle();
        expect(awake, [true, false, true, false]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(awake, [true, false, true, false]);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        messenger.setMockMethodCallHandler(ReaderDisplay.channel, null);
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
