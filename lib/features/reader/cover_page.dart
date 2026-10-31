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
        if (!moving) return child!;
        final lower = cover ? offset >= 0 : offset < 0;
        final phase =
            (cover
                    ? offset.abs()
                    : lower
                    ? 1 + offset
                    : offset)
                .clamp(0.0, 1.0);
        final radius = motion.cornerRadius * math.min(1, phase * 12);
        final tint = background.computeLuminance() < .1 && !lower
            ? motion.tint.clamp(0, .12) *
                  math.pow(math.max(0, (phase - .25) / .75), 2.4)
            : 0.0;
        final dim = lower && !cover
            ? .12 * math.pow((-offset).clamp(0.0, 1.0), 1.6)
            : 0.0;
        Widget sheet = ColorFiltered(
          colorFilter: ColorFilter.matrix([
            (1 - tint) * (1 - dim),
            0,
            0,
            0,
            tint * 128,
            0,
            (1 - tint) * (1 - dim),
            0,
            0,
            tint * 128,
            0,
            0,
            (1 - tint) * (1 - dim),
            0,
            tint * 128,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: child!,
        );
        if (!lower) {
          sheet = ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: sheet,
          );
        }
        if (lower && !cover) {
          sheet = ClipPath(
            clipper: _UnderSheetClipper(offset, radius, reverse),
            child: sheet,
          );
        }
        return Transform.translate(
          offset: Offset(
            cover && lower
                ? offset * w * sign
                : !cover && lower
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
  const _UnderSheetClipper(this.offset, this.radius, this.reverse);
  final double offset, radius;
  final bool reverse;
  @override
  Path getClip(Size size) {
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
      offset != old.offset || radius != old.radius || reverse != old.reverse;
}
