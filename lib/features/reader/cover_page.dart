import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/page_motion.dart';

/// Keeps the lower page stationary while the upper page slides over it.
/// Uses the existing PageView position, so dragging and animation need no
/// screenshots, additional decoding, or work on each page's contents.
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
  final bool reverse;
  final Color background;
  final Widget child;
  final PageMotion motion;
  final bool cover;
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
        final offset = page - index;
        final lower = cover && offset >= 0 && offset < 1;
        final moving = page % 1 > .001 && page % 1 < .999;
        return Transform.translate(
          offset: Offset(
            lower ? offset * constraints.maxWidth * (reverse ? -1 : 1) : 0,
            0,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: moving && !lower
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .3),
                        blurRadius: 12,
                        offset: Offset(reverse ? 4 : -4, 0),
                      ),
                    ]
                  : const [],
            ),
            child: moving && !lower
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(
                      motion.cornerRadius *
                          math.sin(math.pi * offset.abs().clamp(0, 1)),
                    ),
                    child: ColorFiltered(
                      colorFilter: ColorFilter.matrix([
                        1 - motion.tint,
                        0,
                        0,
                        0,
                        motion.tint * 255,
                        0,
                        1 - motion.tint,
                        0,
                        0,
                        motion.tint * 255,
                        0,
                        0,
                        1 - motion.tint,
                        0,
                        motion.tint * 255,
                        0,
                        0,
                        0,
                        1,
                        0,
                      ]),
                      child: child!,
                    ),
                  )
                : child,
          ),
        );
      },
    ),
  );
}
