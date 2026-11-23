import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/epub_reader_chrome.dart';

void main() {
  testWidgets('the EPUB toolbar centers progress between unequal controls', (
    tester,
  ) async {
    const toolbar = ValueKey('epub-toolbar');
    const trailing = ValueKey('epub-trailing');
    for (final width in [720.0, 300.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              child: const EpubToolbarLayout(
                key: toolbar,
                leading: SizedBox(width: 40, height: 40),
                center: Text('62%'),
                trailing: SizedBox(key: trailing, width: 260, height: 40),
              ),
            ),
          ),
        ),
      );
      final progress = tester.getRect(find.text('62%'));
      expect(progress.center.dx, tester.getCenter(find.byKey(toolbar)).dx);
      expect(
        progress.right,
        lessThanOrEqualTo(tester.getRect(find.byKey(trailing)).left),
      );
    }
  });

  testWidgets('the touch selection menu fits a narrow reader', (tester) async {
    var invoked = '';
    const labels = [
      'Copy',
      'Highlight',
      'Dictionary',
      'Add Note',
      'Search',
      'Translate',
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 420,
            child: EpubSelectionMenu(
              touch: true,
              anchor: const Rect.fromLTRB(.43, .52, .57, .57),
              actions: [
                for (final label in labels)
                  (
                    label: label,
                    icon: Icons.edit,
                    invoke: () => invoked = label,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final material = find
        .descendant(
          of: find.byType(EpubSelectionMenu),
          matching: find.byType(Material),
        )
        .first;
    expect(tester.getSize(material).width, lessThanOrEqualTo(320));
    expect(tester.getSize(material).height, lessThanOrEqualTo(110));
    for (final label in labels) {
      expect(find.byTooltip(label).hitTestable(), findsOneWidget);
    }
    await tester.tap(find.byTooltip('Copy'));
    expect(invoked, 'Copy');
  });

  testWidgets(
    'desktop panel slides over the page and reflows behind its snapshot',
    (tester) async {
      const page = ValueKey('reading-page'), panel = ValueKey('reader-panel');
      var captures = 0;
      final laidOut = <int>[];
      var settled = Completer<void>();
      final captured = Completer<void>();
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
                    await captured.future;
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
      expect(tester.getRect(find.byKey(page)), pageRegion);
      expect(captures, 1);
      captured.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final openingPanel = tester.getRect(find.byKey(panel));
      final resized = tester.getRect(find.byKey(page));
      expect(resized.width, lessThan(pageRegion.width));
      expect(openingPanel.left, greaterThan(resized.right));
      expect(openingPanel.left, lessThan(pageRegion.right));
      expect(openingPanel.right, greaterThan(pageRegion.right));
      expect(laidOut, [720]);
      expect(find.byType(RawImage), findsNWidgets(2));
      settled.complete();
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(panel)).left,
        closeTo(resized.right, .1),
      );
      expect(captures, 1);
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

  testWidgets('the annotation filters stay in aligned rows after selection', (
    tester,
  ) async {
    final selection = ValueNotifier('Tutto');
    addTearDown(selection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 330,
            child: ValueListenableBuilder(
              valueListenable: selection,
              builder: (_, selected, _) => EpubAnnotationFilterGrid<String>(
                options: [
                  for (final title in [
                    'Tutto',
                    'Segnalibri',
                    'Evidenziazioni',
                    'Note',
                  ])
                    (value: title, label: title, color: null),
                ],
                selected: selected,
                select: (value) => selection.value = value,
              ),
            ),
          ),
        ),
      ),
    );
    List<Rect> positions() => tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .map((chip) => tester.getRect(find.byWidget(chip)))
        .toList();
    final before = positions();
    expect(before[0].width, before[1].width);
    expect(before[0].top, before[1].top);
    expect(before[0].left, before[2].left);
    expect(before[1].left, before[3].left);
    expect(before[2].top, greaterThan(before[0].bottom));
    await tester.tap(find.text('Evidenziazioni'));
    await tester.pumpAndSettle();
    expect(selection.value, 'Evidenziazioni');
    expect(positions(), before);
  });
}
