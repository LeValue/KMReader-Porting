import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/page_motion.dart';

/// The earlier sheet stays above the later one in both drag directions. The
/// lower sheet moves only 10% of a viewport and is clipped around the upper one,
/// preserving paint order without additional page rasterization.
class CoverPage extends StatelessWidget {
  const CoverPage({
    super.key,
    required this.controller,
    required this.index,
    required this.reverse,
    required this.background,
    required this.child,
    this.motion = const PageMotion(),
    this.cover = true,
  });
  final PageController controller;
  final int index;
  final bool reverse, cover;
  final Color background;
  final Widget child;
  final PageMotion motion;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: controller,
      child: ColoredBox(color: background, child: child),
      builder: (context, child) {
        final page =
            controller.hasClients && controller.position.hasContentDimensions
            ? controller.page ?? controller.initialPage.toDouble()
            : controller.initialPage.toDouble();
        final offset = page - index,
            sign = reverse ? -1.0 : 1.0,
            w = constraints.maxWidth;
        final moving = page % 1 > .001 && page % 1 < .999;
        final lower = cover ? offset >= 0 : offset < 0;
        Widget sheet = ClipPath(
          clipper: _UnderSheetClipper(
            offset,
            0,
            reverse,
            moving && lower && !cover,
          ),
          child: CustomPaint(
            foregroundPainter: _PageShade(
              offset,
              reverse,
              cover,
              moving && lower,
            ),
            child: child!,
          ),
        );
        return Transform.translate(
          offset: Offset(
            moving && cover && lower
                ? offset * w * sign
                : moving && !cover && lower
                ? .9 * offset * w * sign
                : 0,
            0,
          ),
          child: sheet,
        );
      },
    ),
  );
}

class _UnderSheetClipper extends CustomClipper<Path> {
  const _UnderSheetClipper(this.offset, this.radius, this.reverse, this.active);
  final double offset, radius;
  final bool reverse, active;
  @override
  Path getClip(Size size) {
    if (!active) return Path()..addRect(Offset.zero & size);
    final right = .9 * -offset * size.width;
    final upper = Rect.fromLTWH(right - size.width, 0, size.width, size.height);
    final r = reverse
        ? Rect.fromLTRB(
            size.width - upper.right,
            0,
            size.width - upper.left,
            size.height,
          )
        : upper;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(radius)));
  }

  @override
  bool shouldReclip(_UnderSheetClipper old) =>
      offset != old.offset ||
      radius != old.radius ||
      reverse != old.reverse ||
      active != old.active;
}

class _PageShade extends CustomPainter {
  const _PageShade(this.offset, this.reverse, this.cover, this.active);
  final double offset;
  final bool reverse, cover, active;
  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    final p = (cover ? offset : 1 + offset).clamp(0.0, 1.0);
    final wave = math.sin(math.pi * p);
    final edge = cover ? (1 - p) * size.width : -.9 * offset * size.width;
    final seam = reverse ? size.width - edge : edge;
    final direction = (cover ? -1.0 : 1.0) * (reverse ? -1 : 1);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: .08 * wave),
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader =
            LinearGradient(
              colors: direction > 0
                  ? [
                      Colors.black.withValues(alpha: .10 * wave),
                      Colors.transparent,
                    ]
                  : [
                      Colors.transparent,
                      Colors.black.withValues(alpha: .10 * wave),
                    ],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ).createShader(
              Rect.fromPoints(
                Offset(seam, 0),
                Offset(seam + direction * size.width * .45, size.height),
              ),
            ),
    );
  }

  @override
  bool shouldRepaint(_PageShade old) =>
      offset != old.offset ||
      reverse != old.reverse ||
      cover != old.cover ||
      active != old.active;
}
