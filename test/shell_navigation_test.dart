import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/ui/shell_navigation.dart';
import 'package:kmreader/ui/theme.dart';

void main() {
  for (final width in [320.0, 360.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('Italian bottom buttons fit $width at text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const labels = [
          'Dashboard',
          'Libreria',
          'Elenchi',
          'Cerca',
          'Libri locali',
          'Impostazioni',
        ];
        const icons = [
          CupertinoIcons.house,
          CupertinoIcons.book,
          CupertinoIcons.rectangle_stack,
          CupertinoIcons.search,
          CupertinoIcons.folder,
          CupertinoIcons.gear,
        ];
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 800),
                textScaler: TextScaler.linear(scale),
                padding: const EdgeInsets.only(bottom: 24),
              ),
              child: Scaffold(
                bottomNavigationBar: ShellNavigationBar(
                  selectedIndex: 5,
                  labels: labels,
                  icons: icons,
                  onSelected: (value) => selected = value,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final bar = tester.getRect(find.byType(ShellNavigationBar));
        final ys = <double>[];
        for (var i = 0; i < labels.length; i++) {
          final label = find.text(labels[i]);
          final paragraph = tester.renderObject<RenderParagraph>(label);
          expect(paragraph.maxLines, 1);
          expect(paragraph.softWrap, false);
          final rect = tester.getRect(label);
          expect(rect.bottom, lessThanOrEqualTo(bar.bottom - 24));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
          ys.add(tester.getCenter(find.byIcon(icons[i])).dy);
          await tester.tap(find.byIcon(icons[i]));
          expect(selected, i);
        }
        expect(
          ys.reduce((a, b) => a > b ? a : b) -
              ys.reduce((a, b) => a < b ? a : b),
          lessThan(.01),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
