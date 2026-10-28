import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Raster overlays keep native browser views stationary while Flutter paints
/// transitions. Images are released after the overlay's final frame.
class ReaderPageTransition extends StatefulWidget {
  const ReaderPageTransition({
    super.key,
    required this.child,
    required this.capture,
  });
  final Widget child;
  final Future<Uint8List?> Function() capture;
  @override
  State<ReaderPageTransition> createState() => ReaderPageTransitionState();
}

class ReaderPageTransitionState extends State<ReaderPageTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
  );
  ui.Image? _before, _after;
  String _style = 'none';
  int _direction = 1;
  bool _running = false;
  final _queue = <(String, int, Future<void> Function())>[];
  Future<ui.Image?> _capture() async {
    try {
      final bytes = await widget.capture();
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
      return;
    }
    _running = true;
    ui.Image? before, after;
    try {
      if (style == 'none') {
        await move();
        return;
      }
      before = await _capture();
      if (!mounted) return;
      if (before == null) {
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
      after = await _capture();
      if (!mounted) return;
      setState(() => _after = after);
      await _animation.forward(from: 0).orCancel;
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

  @override
  void dispose() {
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
    this.direction,
  );
  final ui.Image before;
  final ui.Image? after;
  final double progress;
  final String style;
  final int direction;
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
    final p = Curves.easeOutCubic.transform(progress);
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
      if (direction < 0) {
        canvas.translate(size.width, 0);
        canvas.scale(-1, 1);
      }
      final edge = size.width * (1 - p);
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, edge, size.height));
      if (direction < 0) {
        canvas.translate(size.width, 0);
        canvas.scale(-1, 1);
      }
      image(canvas, before, size);
      canvas.restore();
      final radius = size.width * .09 * math.sin(math.pi * p);
      _shadow(canvas, size, edge);
      if (radius > 0) {
        const slices = 24;
        for (var i = 0; i < slices; i++) {
          final a = i * math.pi / slices, b = (i + 1) * math.pi / slices;
          final x1 = edge + radius * math.sin(a),
              x2 = edge + radius * math.sin(b);
          final t1 = ((edge + radius * a) / size.width).clamp(0.0, 1.0),
              t2 = ((edge + radius * b) / size.width).clamp(0.0, 1.0);
          final u1 = before.width * (direction < 0 ? 1 - t1 : t1),
              u2 = before.width * (direction < 0 ? 1 - t2 : t2);
          final vertices = ui.Vertices(
            ui.VertexMode.triangleStrip,
            [
              Offset(x1, 0),
              Offset(x1, size.height),
              Offset(x2, 0),
              Offset(x2, size.height),
            ],
            textureCoordinates: [
              Offset(u1, 0),
              Offset(u1, before.height.toDouble()),
              Offset(u2, 0),
              Offset(u2, before.height.toDouble()),
            ],
          );
          final shade = (.68 + .32 * math.cos(a).abs());
          final paint = Paint()
            ..shader = ImageShader(
              before,
              TileMode.clamp,
              TileMode.clamp,
              Matrix4.identity().storage,
            )
            ..colorFilter = ColorFilter.matrix([
              shade,
              0,
              0,
              0,
              0,
              0,
              shade,
              0,
              0,
              0,
              0,
              0,
              shade,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
            ]);
          canvas.drawVertices(vertices, BlendMode.srcOver, paint);
          vertices.dispose();
        }
      }
    }
    canvas.restore();
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
