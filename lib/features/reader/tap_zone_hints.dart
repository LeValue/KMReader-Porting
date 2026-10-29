import 'package:flutter/material.dart';

import '../../core/models.dart';
import 'tap_zones.dart';

class TapZoneHints extends StatelessWidget {
  const TapZoneHints({super.key, required this.preferences});
  final ReaderPreferences preferences;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _TapZonePainter(preferences),
      child: const SizedBox.expand(),
    ),
  );
}

class _TapZonePainter extends CustomPainter {
  _TapZonePainter(this.preferences);
  final ReaderPreferences preferences;
  @override
  void paint(Canvas canvas, Size size) {
    if (preferences.tapMode == 'none') return;
    final cells = preferences.tapMode == 'tSplit'
        ? [
            const Rect.fromLTWH(0, 0, 1, .12),
            const Rect.fromLTWH(0, .12, .5, .88),
            const Rect.fromLTWH(.5, .12, .5, .88),
          ]
        : [
            for (var row = 0; row < 3; row++)
              for (var column = 0; column < 3; column++)
                Rect.fromLTWH(column / 3, row / 3, 1 / 3, 1 / 3),
          ];
    final labelled = <TapAction>{};
    for (final cell in cells) {
      final action = tapAction(cell.center.dx, cell.center.dy, preferences);
      final rect = Rect.fromLTWH(
        cell.left * size.width,
        cell.top * size.height,
        cell.width * size.width,
        cell.height * size.height,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = switch (action) {
            TapAction.previous => Colors.blue.withValues(alpha: .25),
            TapAction.next => Colors.green.withValues(alpha: .25),
            TapAction.controls => Colors.grey.withValues(alpha: .25),
          },
      );
      if (!labelled.add(action)) continue;
      final center = rect.center;
      canvas.drawCircle(
        center,
        20,
        Paint()..color = Colors.black.withValues(alpha: .7),
      );
      final text = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: switch (action) {
            TapAction.previous => '←',
            TapAction.next => '→',
            TapAction.controls => '⋯',
          },
          style: const TextStyle(fontSize: 24, color: Colors.white),
        ),
      )..layout();
      text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(_TapZonePainter old) => old.preferences != preferences;
}
