import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../core/page_motion.dart';

import 'package:flutter/services.dart';

/// Raster overlays keep native browser views stationary while Flutter paints
/// transitions. Images are released after the overlay's final frame.
class ReaderPageTransition extends StatefulWidget {
  const ReaderPageTransition({
    super.key,
    required this.child,
    this.capture,
    this.captureImage,
    this.motion = const PageMotion(),
  });
  final Widget child;
  final Future<Uint8List?> Function()? capture;
  final Future<ui.Image?> Function()? captureImage;
  final PageMotion motion;
  @override
  State<ReaderPageTransition> createState() => ReaderPageTransitionState();
}

class ReaderPageTransitionState extends State<ReaderPageTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.motion.duration),
  );
  ui.Image? _before, _after;
  String _style = 'none';
  int _direction = 1;
  bool _running = false, _interrupt = false;
  _CurlDrag? _activeDrag;
  void cancelGesture() {
    _activeDrag?.cancel();
    _animation.stop(canceled: true);
  }

  final _queue = <(String, int, Future<void> Function())>[];
  Future<ui.Image?> _capture() async {
    try {
      if (widget.captureImage != null) return await widget.captureImage!();
      final bytes = await widget.capture?.call();
      if (bytes == null || bytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> turn(
    String style,
    int direction,
    Future<void> Function() move,
  ) async {
    if (_running) {
      if (_queue.length < 8) _queue.add((style, direction, move));
      if (_activeDrag != null) {
        _activeDrag!.cancel();
      } else {
        _interrupt = true;
        _animation.stop(canceled: true);
      }
      return;
    }
    _running = true;
    _interrupt = _queue.isNotEmpty;
    ui.Image? before, after;
    try {
      if (style == 'none' || _interrupt) {
        await move();
        return;
      }
      before = await _capture();
      if (!mounted) return;
      if (before == null || _interrupt) {
        await move();
        return;
      }
      setState(() {
        _before = before;
        _after = null;
        _style = style;
        _direction = direction;
        _animation.value = 0;
      });
      await WidgetsBinding.instance.endOfFrame;
      await move();
      if (_interrupt) return;
      after = await _capture();
      if (!mounted) return;
      setState(() => _after = after);
      if (_interrupt) return;
      _animation.duration = Duration(milliseconds: widget.motion.duration);
      await _animation.animateTo(1, curve: Curves.easeInOutCubic).orCancel;
    } on TickerCanceled {
      // Closing a reader cancels its overlay, preserving the last committed page.
    } finally {
      if (mounted) {
        setState(() {
          _before = null;
          _after = null;
        });
        await WidgetsBinding.instance.endOfFrame;
      }
      before?.dispose();
      after?.dispose();
      _running = false;
      if (mounted && _queue.isNotEmpty) {
        final next = _queue.removeAt(0);
        unawaited(turn(next.$1, next.$2, next.$3));
      }
    }
  }

  Drag drag({
    required bool reverse,
    required double width,
    required Future<bool> Function(int delta) preview,
    required Future<void> Function(int delta, bool commit) finish,
  }) => _CurlDrag(this, reverse, width, preview, finish);

  Future<void> _interactive(_CurlDrag drag) async {
    if (_running) return;
    _activeDrag = drag;
    _running = true;
    ui.Image? before;
    var previewed = false;
    try {
      before = await _capture();
      if (!mounted || drag.canceled) return;
      if (before == null) {
        if (await drag.decision.future) await drag.finish(drag.delta, true);
        return;
      }
      setState(() {
        _before = before;
        _after = null;
        _style = 'curl';
        _direction = drag.physical;
        _animation.value = drag.progress;
      });
      await WidgetsBinding.instance.endOfFrame;
      previewed = await drag.preview(drag.delta);
      if (!previewed) return;
      final commit = await drag.decision.future && !drag.canceled;
      if (!mounted) return;
      if (!drag.canceled) {
        await _animation
            .animateTo(
              commit ? 1 : 0,
              duration: Duration(
                milliseconds:
                    (widget.motion.duration *
                            (commit ? 1 - drag.progress : drag.progress))
                        .round()
                        .clamp(70, 300),
              ),
              curve: Curves.easeOutCubic,
            )
            .orCancel;
      }
      await drag.finish(drag.delta, commit && !drag.canceled);
      previewed = false;
    } on TickerCanceled {
      /* Reader closed during a gesture. */
    } finally {
      if (previewed && mounted) await drag.finish(drag.delta, false);
      if (mounted) {
        setState(() {
          _before = null;
          _after = null;
        });
        await WidgetsBinding.instance.endOfFrame;
      }
      before?.dispose();
      if (_activeDrag == drag) _activeDrag = null;
      _running = false;
      if (mounted && _queue.isNotEmpty) {
        final next = _queue.removeAt(0);
        unawaited(turn(next.$1, next.$2, next.$3));
      }
    }
  }

  @override
  void dispose() {
    _activeDrag?.cancel();
    _queue.clear();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      if (_before != null)
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _animation,
              builder: (context, _) => CustomPaint(
                painter: PageTurnPainter(
                  _before!,
                  _after,
                  _animation.value,
                  _style,
                  _direction,
                  motion: widget.motion,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class PageTurnPainter extends CustomPainter {
  PageTurnPainter(
    this.before,
    this.after,
    this.progress,
    this.style,
    this.direction, {
    this.motion = const PageMotion(),
  });
  final ui.Image before;
  final ui.Image? after;
  final double progress;
  final String style;
  final int direction;
  final PageMotion motion;
  void image(
    Canvas canvas,
    ui.Image source,
    Size size, [
    Offset offset = Offset.zero,
  ]) => canvas.drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    offset & size,
    Paint()..filterQuality = FilterQuality.low,
  );
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (after != null) image(canvas, after!, size);
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0) {
      image(canvas, before, size);
      canvas.restore();
      return;
    }
    if (p >= 1) {
      canvas.restore();
      return;
    }
    if (style == 'slide') {
      if (after != null) {
        image(
          canvas,
          after!,
          size,
          Offset(direction * size.width * (1 - p), 0),
        );
      }
      image(canvas, before, size, Offset(-direction * size.width * p, 0));
    } else if (style == 'cover') {
      if (direction > 0) {
        image(canvas, before, size, Offset(-size.width * p, 0));
        _shadow(canvas, size, size.width * (1 - p));
      } else {
        image(canvas, before, size);
        if (after != null) {
          image(canvas, after!, size, Offset(-size.width * (1 - p), 0));
        }
        _shadow(canvas, size, size.width * p);
      }
    } else {
      _curl(canvas, size, p);
    }
    canvas.restore();
  }

  void _curl(Canvas canvas, Size size, double p) {
    final width = size.width, height = size.height;
    final radius = width * .10 * math.sin(math.pi * p);
    final fold = width * (1 - p) - math.pi * radius / 2;
    const columns = 96, rows = 12;
    final positions = <Offset>[],
        textures = <Offset>[],
        colors = <Color>[],
        indices = <int>[];
    final tint = motion.tint * math.min(1, math.sin(math.pi * p) * 2);
    for (var col = 0; col <= columns; col++) {
      final u = width * col / columns;
      for (var row = 0; row <= rows; row++) {
        final y = height * row / rows;
        final base =
            fold + width * .035 * math.sin(math.pi * p) * (row / rows - .5);
        final angle = ((u - base) / math.max(.001, radius)).clamp(0.0, math.pi);
        final x = u <= base
            ? u
            : angle < math.pi
            ? base + radius * math.sin(angle)
            : 2 * base + math.pi * radius - u;
        final z = radius * (1 - math.cos(angle));
        final scale = width * 3 / (width * 3 - z);
        final projected = (x - width / 2) * scale + width / 2;
        positions.add(
          Offset(
            direction > 0 ? projected : width - projected,
            (y - height / 2) * scale + height / 2,
          ),
        );
        textures.add(
          Offset(
            before.width * (direction > 0 ? col / columns : 1 - col / columns),
            before.height * row / rows,
          ),
        );
        final shade = u <= base ? 1.0 : .72 + .28 * math.cos(angle).abs();
        colors.add(
          Color.fromRGBO(
            (shade * 255).round(),
            (shade * 255).round(),
            (shade * 255).round(),
            1,
          ),
        );
        if (col < columns && row < rows) {
          final a = col * (rows + 1) + row, b = a + rows + 1;
          indices.addAll([a, b, a + 1, a + 1, b, b + 1]);
        }
      }
    }
    final outline = Path()..moveTo(positions.first.dx, positions.first.dy);
    for (var col = 1; col <= columns; col++) {
      outline.lineTo(
        positions[col * (rows + 1)].dx,
        positions[col * (rows + 1)].dy,
      );
    }
    for (var col = columns; col >= 0; col--) {
      final point = positions[col * (rows + 1) + rows];
      outline.lineTo(point.dx, point.dy);
    }
    outline.close();
    canvas.drawShadow(outline, Colors.black.withValues(alpha: .35), 12, false);
    final mesh = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: textures,
      colors: colors,
      indices: indices,
    );
    final paint = Paint()
      ..shader = ImageShader(
        before,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.identity().storage,
      )
      ..filterQuality = FilterQuality.medium
      ..colorFilter = ColorFilter.matrix([
        1 - tint,
        0,
        0,
        0,
        tint * 255,
        0,
        1 - tint,
        0,
        0,
        tint * 255,
        0,
        0,
        1 - tint,
        0,
        tint * 255,
        0,
        0,
        0,
        1,
        0,
      ]);
    canvas.drawVertices(mesh, BlendMode.modulate, paint);
    mesh.dispose();
  }

  void _shadow(Canvas canvas, Size size, double edge) {
    if (progress <= 0 || progress >= 1) return;
    final rect = Rect.fromLTWH(edge, 0, size.width * .06, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.black.withValues(alpha: .2 * math.sin(math.pi * progress)),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(PageTurnPainter old) =>
      old.progress != progress ||
      old.before != before ||
      old.after != after ||
      old.style != style ||
      old.direction != direction;
}

class _CurlDrag implements Drag {
  _CurlDrag(this.owner, this.reverse, this.width, this.preview, this.finish);
  final ReaderPageTransitionState owner;
  final bool reverse;
  final double width;
  final Future<bool> Function(int) preview;
  final Future<void> Function(int, bool) finish;
  final decision = Completer<bool>();
  double distance = 0, progress = 0;
  int physical = 0;
  bool canceled = false;
  int get delta => reverse ? -physical : physical;
  @override
  void update(DragUpdateDetails details) {
    if (decision.isCompleted || owner._running && physical == 0) return;
    distance += details.delta.dx;
    if (physical == 0 && distance.abs() > 10) {
      physical = distance < 0 ? 1 : -1;
      unawaited(owner._interactive(this));
    }
    progress = (-distance * physical / width).clamp(0, 1);
    if (physical != 0 && owner.mounted) owner._animation.value = progress;
  }

  @override
  void end(DragEndDetails details) {
    if (!decision.isCompleted) {
      decision.complete(
        progress > .28 ||
            progress > .06 &&
                -details.velocity.pixelsPerSecond.dx * physical > 450,
      );
    }
  }

  @override
  void cancel() {
    canceled = true;
    if (!decision.isCompleted) decision.complete(false);
  }
}
