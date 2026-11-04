import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Physical leaves share a height and meet at the spine. Letterboxing belongs
/// outside the complete spread, never between two independently centered pages.
List<Rect> comicLeafBounds(
  Size viewport,
  List<double> aspects, {
  String fit = 'contain',
}) {
  if (aspects.isEmpty) return const [];
  final safe = aspects.map((a) => a.isFinite && a > 0 ? a : 1.0).toList();
  if (fit != 'contain') {
    return List.generate(
      safe.length,
      (i) => Rect.fromLTWH(
        i * viewport.width / safe.length,
        0,
        viewport.width / safe.length,
        viewport.height,
      ),
    );
  }
  final total = safe.fold<double>(0, (a, b) => a + b);
  final height = math.min(viewport.height, viewport.width / total);
  var left = (viewport.width - height * total) / 2;
  return [
    for (final aspect in safe)
      (() {
        final rect = Rect.fromLTWH(
          left,
          (viewport.height - height) / 2,
          height * aspect,
          height,
        );
        left = rect.right;
        return rect;
      })(),
  ];
}

class ComicSpread extends StatelessWidget {
  const ComicSpread({
    super.key,
    required this.aspects,
    required this.children,
    this.rtl = false,
    this.fit = 'contain',
  });
  final List<double> aspects;
  final List<Widget> children;
  final bool rtl;
  final String fit;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final ordered = rtl ? children.reversed.toList() : children;
      final bounds = comicLeafBounds(
        constraints.biggest,
        rtl ? aspects.reversed.toList() : aspects,
        fit: fit,
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < ordered.length; i++)
            Positioned.fromRect(rect: bounds[i], child: ordered[i]),
        ],
      );
    },
  );
}

/// A physical sheet needs matching fitted surfaces on both sides of a turn.
/// Source image resolution is irrelevant; compare its actual on-screen bounds.
bool comicSheetsMatch(List<Rect> before, List<Rect> after) {
  if (before.length != after.length) return false;
  for (var i = 0; i < before.length; i++) {
    final a = before[i], b = after[i];
    final tolerance = math.max(2.0, math.min(a.width, a.height) * .02);
    if ((a.left - b.left).abs() > tolerance ||
        (a.top - b.top).abs() > tolerance ||
        (a.right - b.right).abs() > tolerance ||
        (a.bottom - b.bottom).abs() > tolerance) {
      return false;
    }
  }
  return true;
}
