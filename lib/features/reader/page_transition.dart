import 'motion_timing.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../core/page_motion.dart';
import 'curl_sheet.dart';

import 'package:flutter/services.dart';

class PreparedPageTurn {
  PreparedPageTurn(this.before, this.after, this.bounds, this.backBounds);
  final ui.Image before, after;
  final Rect bounds;
  final Rect? backBounds;
}

/// Raster overlays keep native browser views stationary while Flutter paints
/// transitions. Images are released after the overlay's final frame.
class ReaderPageTransition extends StatefulWidget {
  const ReaderPageTransition({
    super.key,
    required this.child,
    this.prepare,
    this.canTurn,
    this.capture,
    this.captureImage,
    this.sheetBounds,
    this.backBounds,
    this.motion = const PageMotion(),
  });
  final PreparedPageTurn? Function(int direction)? prepare;
  final bool Function(int direction)? canTurn;
  final Widget child;
  final Future<Uint8List?> Function()? capture;
  final Future<ui.Image?> Function()? captureImage;
  final Rect Function(Size size, int direction)? sheetBounds;
  final Rect? Function(Size size, int direction)? backBounds;
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
  Rect? _sheetBounds, _backBounds;
  String _style = 'none';
  int _direction = 1;
  bool _running = false, _interrupt = false, _previewReady = true;
  _CurlDrag? _activeDrag;
  void cancelGesture() {
    _activeDrag?.cancel();
    _animation.stop(canceled: true);
  }

  void _updateCurlDrag(double progress, bool foldChanged) {
    if (!_previewReady) return;
    if (_animation.value == progress && foldChanged) setState(() {});
    _animation.value = progress;
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
    if (widget.canTurn?.call(direction) == false) return;
    _running = true;
    _interrupt = _queue.isNotEmpty;
    ui.Image? before, after;
    try {
      if (style == 'none' || _interrupt) {
        await move();
        return;
      }
      final prepared = widget.prepare?.call(direction);
      if (prepared != null) {
        before = prepared.before;
        after = prepared.after;
        setState(() {
          _before = before;
          _after = after;
          _sheetBounds = prepared.bounds;
          _backBounds = prepared.backBounds;
          _style = style;
          _direction = direction;
          _animation.value = 0;
        });
        _animation.duration = Duration(milliseconds: widget.motion.duration);
        try {
          await _animation
              .animateWith(
                ReaderMotionSimulation(
                  _animation.value,
                  1,
                  Duration(milliseconds: widget.motion.duration),
                ),
              )
              .orCancel;
        } on TickerCanceled {
          if (!mounted) return;
        }
        if (mounted) await move();
        return;
      }
      final box = context.findRenderObject();
      _sheetBounds = box is RenderBox
          ? widget.sheetBounds?.call(box.size, direction)
          : null;
      _backBounds = box is RenderBox
          ? widget.backBounds?.call(box.size, direction)
          : null;
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
      await _animation
          .animateWith(
            ReaderMotionSimulation(
              _animation.value,
              1,
              Duration(milliseconds: widget.motion.duration),
            ),
          )
          .orCancel;
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
    if (_running || widget.canTurn?.call(drag.physical) == false) return;
    _activeDrag = drag;
    _running = true;
    _previewReady = false;
    ui.Image? before, after;
    var previewed = false;
    try {
      final prepared = widget.prepare?.call(drag.physical);
      if (prepared != null) {
        before = prepared.before;
        after = prepared.after;
        _sheetBounds = prepared.bounds;
        _backBounds = prepared.backBounds;
        setState(() {
          _before = before;
          _after = after;
          _style = 'curl';
          _direction = drag.physical;
          _previewReady = true;
          _animation.value = drag.progress;
        });
      } else {
        final box = context.findRenderObject();
        _sheetBounds = box is RenderBox
            ? widget.sheetBounds?.call(box.size, drag.physical)
            : null;
        _backBounds = box is RenderBox
            ? widget.backBounds?.call(box.size, drag.physical)
            : null;
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
          _animation.value = 0;
        });
        await WidgetsBinding.instance.endOfFrame;
        previewed = await drag.preview(drag.delta);
        if (!previewed) return;
        after = await _capture();
        if (!mounted) return;
        setState(() {
          _after = after;
          _previewReady = true;
          _animation.value = drag.progress;
        });
      }
      final commit = await drag.decision.future && !drag.canceled;
      if (!mounted) return;
      if (!drag.canceled) {
        await _animation
            .animateWith(
              ReaderMotionSimulation(
                _animation.value,
                commit ? 1 : 0,
                Duration(
                  milliseconds:
                      (widget.motion.duration *
                              (commit ? 1 - drag.progress : drag.progress))
                          .round()
                          .clamp(100, 380),
                ),
                automatic: false,
                velocity: drag.velocity,
              ),
            )
            .orCancel;
      }
      await drag.finish(drag.delta, commit && !drag.canceled);
      await WidgetsBinding.instance.endOfFrame;
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
      after?.dispose();
      if (_activeDrag == drag) _activeDrag = null;
      _running = false;
      _previewReady = true;
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

  double get _grabY {
    final origin = _activeDrag?.origin;
    final box = context.findRenderObject();
    if (origin == null || box is! RenderBox || box.size.height <= 0) return .5;
    final bounds = _sheetBounds ?? Offset.zero & box.size;
    return ((box.globalToLocal(origin).dy - bounds.top) / bounds.height).clamp(
      0,
      1,
    );
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
                  foldSlope: _activeDrag?.slope ?? 0,
                  grabY: _grabY,
                  sheetBounds: _sheetBounds,
                  backBounds: _backBounds,
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
    this.foldSlope = 0,
    this.grabY = .5,
    this.sheetBounds,
    this.backBounds,
  });
  final double foldSlope, grabY;
  final Rect? sheetBounds, backBounds;
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
    double opacity = 1,
  ]) => canvas.drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    offset & size,
    Paint()
      ..filterQuality = FilterQuality.high
      ..color = Colors.white.withValues(alpha: opacity),
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
    final bounds = sheetBounds ?? Offset.zero & size;
    if (bounds.isEmpty) return;
    final width = bounds.width, height = bounds.height;
    // In a spread, the stationary leaf stays in the old spread. The back of
    // the turning leaf is the opposite leaf of the incoming spread.
    if (backBounds != null) {
      canvas.save();
      canvas.clipRect(
        direction > 0
            ? Rect.fromLTWH(0, 0, bounds.left, size.height)
            : Rect.fromLTWH(
                bounds.right,
                0,
                size.width - bounds.right,
                size.height,
              ),
      );
      image(
        canvas,
        before,
        size,
        Offset.zero,
        1 - Curves.easeInOut.transform(((p - .72) / .28).clamp(0, 1)),
      );
      canvas.restore();
    }
    const columns = 96, rows = 16, count = (columns + 1) * (rows + 1);
    final positions = Float32List(count * 2);
    final textures = Float32List(count * 2);
    final backTextures = Float32List(count * 2);
    final colors = Int32List(count);
    final normals = Float32List(count);
    final depths = Float32List(count);
    final frontIndices = <int>[], backIndices = <int>[];
    final wave = math.sin(math.pi * p);
    final slope = foldSlope * wave;
    final nx = 1 / math.sqrt(1 + slope * slope),
        ny = slope / math.sqrt(1 + slope * slope);
    final settle = Curves.easeInOut.transform(((p - .72) / .28).clamp(0, 1));
    final exit = backBounds == null
        ? settle *
              (direction > 0
                  ? bounds.left + 16
                  : size.width - bounds.right + 16)
        : 0.0;
    final originY = height * grabY;
    final hinge = direction > 0 ? bounds.left : bounds.right;
    final cone = ((.5 - grabY) * .65 + foldSlope * .35).clamp(-.45, .45);
    for (var col = 0; col <= columns; col++) {
      final sx = width * col / columns;
      for (var row = 0; row <= rows; row++) {
        final sy = height * row / rows;
        final u = nx * sx + ny * (sy - originY);
        final v = -ny * sx + nx * (sy - originY);
        final sheet = CurlSheet(
          width,
          p,
          cone: (1 + cone * v / height).clamp(.65, 1.35),
        );
        final point = sheet.point(u);
        final x = nx * point.x - ny * v;
        final y = ny * point.x + nx * v;
        final scale = width * 3 / (width * 3 - point.z);
        final i = col * (rows + 1) + row, j = i * 2;
        positions[j] = hinge + direction * (x * scale - exit);
        positions[j + 1] = bounds.top + originY + y * scale;
        final landing = backBounds;
        if (landing != null && settle > 0) {
          final targetX =
              landing.left +
              landing.width *
                  (direction > 0 ? 1 - col / columns : col / columns);
          final targetY = landing.top + landing.height * row / rows;
          positions[j] += (targetX - positions[j]) * settle;
          positions[j + 1] += (targetY - positions[j + 1]) * settle;
        }
        textures[j] =
            (bounds.left + (direction > 0 ? sx : width - sx)) *
            before.width /
            size.width;
        textures[j + 1] = (bounds.top + sy) * before.height / size.height;
        final back = after == null ? null : backBounds;
        backTextures[j] = back == null
            ? textures[j]
            : (back.left +
                      back.width *
                          (direction > 0 ? 1 - col / columns : col / columns)) *
                  after!.width /
                  size.width;
        backTextures[j + 1] = back == null
            ? textures[j + 1]
            : (back.top + back.height * row / rows) *
                  after!.height /
                  size.height;
        normals[i] = math.cos(point.angle);
        depths[i] = point.z;
        final rawShade = 1 - .28 * math.pow(math.sin(point.angle).abs(), 1.4);
        final shade =
            ((backBounds == null
                        ? rawShade
                        : rawShade * (1 - settle) + settle) *
                    255)
                .round();
        colors[i] = 0xff000000 | shade << 16 | shade << 8 | shade;
      }
    }
    for (var col = 0; col < columns; col++) {
      for (var row = 0; row < rows; row++) {
        final a = col * (rows + 1) + row, b = a + rows + 1;
        final first = normals[a] + normals[b] + normals[a + 1] >= 0
            ? frontIndices
            : backIndices;
        first.add(a);
        first.add(b);
        first.add(a + 1);
        final second = normals[a + 1] + normals[b] + normals[b + 1] >= 0
            ? frontIndices
            : backIndices;
        second.add(a + 1);
        second.add(b);
        second.add(b + 1);
      }
    }
    // A folded outline crosses itself. Filling it as a shadow made a black
    // diagonal curtain; only cast a soft stroke from the raised free edges.
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: .26 * wave)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    for (final row in [0, rows]) {
      final edge = Path();
      var started = false;
      for (var col = 0; col <= columns; col++) {
        final i = col * (rows + 1) + row;
        if (depths[i] < 1) {
          started = false;
          continue;
        }
        final x = positions[i * 2] + 3, y = positions[i * 2 + 1] + 5;
        if (started) {
          edge.lineTo(x, y);
        } else {
          edge.moveTo(x, y);
          started = true;
        }
      }
      canvas.drawPath(edge, shadow);
    }
    void draw(List<int> indices, bool back) {
      if (indices.isEmpty) return;
      final source = back && backBounds != null && after != null
          ? after!
          : before;
      final mesh = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: back ? backTextures : textures,
        colors: colors,
        indices: Uint16List.fromList(indices),
      );
      final paint = Paint()
        ..shader = ImageShader(
          source,
          TileMode.clamp,
          TileMode.clamp,
          Matrix4.identity().storage,
        )
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(
          alpha: back
              ? 1
              : 1 - Curves.easeInOut.transform(((p - .96) / .04).clamp(0, 1)),
        );
      if (back && backBounds == null) {
        // Paper transmits a faint mirrored impression on a single leaf.
        paint.colorFilter = const ColorFilter.matrix([
          .45,
          0,
          0,
          0,
          140,
          0,
          .45,
          0,
          0,
          140,
          0,
          0,
          .45,
          0,
          140,
          0,
          0,
          0,
          1,
          0,
        ]);
      }
      canvas.drawVertices(mesh, BlendMode.modulate, paint);
      mesh.dispose();
    }

    draw(frontIndices, false);
    draw(backIndices, true);
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
      old.foldSlope != foldSlope ||
      old.grabY != grabY ||
      old.sheetBounds != sheetBounds ||
      old.backBounds != backBounds ||
      old.motion != motion ||
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
  double distance = 0, progress = 0, slope = 0, velocity = 0;
  Offset? origin;
  int physical = 0;
  bool canceled = false;
  int get delta => reverse ? -physical : physical;
  @override
  void update(DragUpdateDetails details) {
    if (decision.isCompleted || owner._running && physical == 0) return;
    origin ??= details.globalPosition - details.delta;
    final oldSlope = slope;
    slope =
        (-(details.globalPosition.dy - origin!.dy) /
                math.max(width * .15, distance.abs()))
            .clamp(-.65, .65);
    distance += details.delta.dx;
    if (physical == 0 && distance.abs() > 10) {
      physical = distance < 0 ? 1 : -1;
      unawaited(owner._interactive(this));
    }
    progress = (-distance * physical / width).clamp(0, 1);
    if (physical != 0 && owner.mounted) {
      owner._updateCurlDrag(progress, slope != oldSlope);
    }
  }

  @override
  void end(DragEndDetails details) {
    velocity = -details.velocity.pixelsPerSecond.dx * physical / width;
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
