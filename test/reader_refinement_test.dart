import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/comic_spread.dart';
import 'package:kmreader/ui/reader_chrome.dart';
import 'package:kmreader/ui/reader_preview.dart';

void main() {
  test(
    'live preview applies while open and coalesces updates behind one layout',
    () async {
      final applied = <int>[], errors = <Object>[];
      final started = Completer<void>(), blocked = Completer<void>();
      var active = 0, maxActive = 0;
      final preview = ReaderPreview<int>(
        (value) async {
          active++;
          if (active > maxActive) maxActive = active;
          applied.add(value);
          if (value == 2) {
            started.complete();
            await blocked.future;
          }
          active--;
        },
        onError: errors.add,
        delay: const Duration(milliseconds: 1),
      );
      preview.schedule(1);
      preview.schedule(2);
      await started.future.timeout(const Duration(seconds: 2));
      expect(applied, [2]);
      preview.schedule(3);
      preview.schedule(4);
      blocked.complete();
      await preview.flush();
      expect(applied, [2, 4]);
      expect(maxActive, 1);
      expect(errors, isEmpty);
      preview.schedule(5);
      await preview.flush();
      expect(applied.last, 5);
    },
  );
  for (final rtl in [false, true]) {
    testWidgets(
      'unequal comic pages meet at the spine without a center gap; rtl=$rtl',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 800,
                height: 500,
                child: ComicSpread(
                  rtl: rtl,
                  aspects: const [.5, .75],
                  children: const [
                    ColoredBox(key: ValueKey('a'), color: Colors.red),
                    ColoredBox(key: ValueKey('b'), color: Colors.blue),
                  ],
                ),
              ),
            ),
          ),
        );
        final a = tester.getRect(find.byKey(const ValueKey('a'))),
            b = tester.getRect(find.byKey(const ValueKey('b')));
        expect(rtl ? b.right : a.right, rtl ? a.left : b.left);
        expect(a.height, b.height);
        expect(a.top, b.top);
        expect(a.width / a.height, .5);
        expect(b.width / b.height, .75);
      },
    );
  }
  for (final paper in [
    Colors.white,
    Colors.black,
    Colors.grey,
    const Color(0xff392f25),
  ]) {
    testWidgets(
      'reader buttons override incompatible app colors on paper $paper',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light().copyWith(
              iconButtonTheme: IconButtonThemeData(
                style: IconButton.styleFrom(foregroundColor: Colors.black),
              ),
            ),
            home: Scaffold(
              backgroundColor: paper,
              body: ReaderCapsule(
                background: paper,
                child: Row(
                  children: [
                    IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
                    const Text('Position'),
                  ],
                ),
              ),
            ),
          ),
        );
        final icon = tester.element(find.byIcon(Icons.close));
        final ink = IconTheme.of(icon).color!;
        final fill = tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(ReaderCapsule),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color!;
        final a = ink.computeLuminance(), b = fill.computeLuminance();
        expect(
          a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05),
          greaterThanOrEqualTo(4.5),
        );
        final text = DefaultTextStyle.of(tester.element(find.text('Position')))
            .style
            .color;
        expect(text, ink);
      },
    );
  }
}
