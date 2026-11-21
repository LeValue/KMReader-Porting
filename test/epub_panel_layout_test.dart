import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/epub_reader_chrome.dart';

void main() {
  testWidgets(
    'desktop panel slides over the page and reflows behind its snapshot',
    (tester) async {
      const page = ValueKey('reading-page'), panel = ValueKey('reader-panel');
      var captures = 0;
      final laidOut = <int>[];
      var settled = Completer<void>();
      final open = ValueNotifier(false);
      addTearDown(open.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 720,
              height: 480,
              child: ValueListenableBuilder(
                valueListenable: open,
                builder: (_, visible, _) => EpubDesktopPanels(
                  panel: visible ? const SizedBox.expand(key: panel) : null,
                  reader: (cover) => Stack(
                    fit: StackFit.expand,
                    children: [
                      const SizedBox.expand(key: page),
                      ?cover,
                    ],
                  ),
                  capture: () async {
                    captures++;
                    final recording = ui.PictureRecorder();
                    Canvas(recording).drawColor(Colors.white, BlendMode.src);
                    final picture = recording.endRecording();
                    final result = picture.toImageSync(2, 2);
                    picture.dispose();
                    return (
                      result,
                      tester.getSize(find.byKey(page)).width.round(),
                    );
                  },
                  settle: (width) {
                    laidOut.add(width);
                    return settled.future;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final pageRegion = tester.getRect(find.byKey(page));
      open.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(tester.getRect(find.byKey(page)), pageRegion);
      final openingPanel = tester.getRect(find.byKey(panel));
      expect(openingPanel.left, lessThan(pageRegion.right));
      expect(openingPanel.right, greaterThan(pageRegion.right));
      expect(captures, 0);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      await tester.pump();
      final resized = tester.getRect(find.byKey(page));
      expect(resized.width, lessThan(pageRegion.width));
      expect(
        tester.getRect(find.byKey(panel)).left,
        closeTo(resized.right, .1),
      );
      expect(captures, 1);
      expect(laidOut, [720]);
      expect(find.byType(RawImage), findsOneWidget);
      settled.complete();
      await tester.pumpAndSettle();
      expect(find.byType(RawImage), findsNothing);

      settled = Completer<void>();
      open.value = false;
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(find.byKey(page)), pageRegion);
      expect(find.byType(RawImage), findsOneWidget);
      expect(captures, 2);
      settled.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(panel), findsNothing);
      expect(find.byType(RawImage), findsNothing);
    },
  );
}
