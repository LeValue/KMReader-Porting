import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// One recognizer owns page dragging, pinching and panning. The surrounding
/// scrollable has no drag recognizer: a second finger can always cancel a turn.
class ReaderViewport extends StatefulWidget {
  const ReaderViewport({
    super.key,
    required this.controller,
    required this.child,
    required this.startScroll,
    this.axis = Axis.horizontal,
    this.onTap,
    this.onContact,
    this.onPinch,
    this.onActivityChanged,
    this.onZoomSettled,
    this.onWheel,
  });
  final TransformationController controller;
  final Widget child;
  final Axis axis;
  final Drag? Function(DragStartDetails) startScroll;
  final ValueChanged<Offset>? onTap;
  final VoidCallback? onContact, onPinch;
  final ValueChanged<bool>? onActivityChanged;
  final ValueChanged<double>? onZoomSettled;
  final ValueChanged<double>? onWheel;
  @override
  State<ReaderViewport> createState() => _ReaderViewportState();
}

class _ReaderViewportState extends State<ReaderViewport>
    with SingleTickerProviderStateMixin {
  final _pointers = <int>{};
  Drag? _drag;
  Timer? _wheelTimer;
  bool _disposed = false;
  bool _multiple = false;
  Offset _origin = Offset.zero, _doubleTap = Offset.zero;
  Matrix4 _initial = Matrix4.identity();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(_animate);
  Animation<Matrix4>? _matrixAnimation;

  double get _scale => widget.controller.value.getMaxScaleOnAxis();
  Size get _size => (context.findRenderObject()! as RenderBox).size;

  void _animate() {
    final animation = _matrixAnimation;
    if (animation != null) widget.controller.value = animation.value;
  }

  Matrix4 _matrix(double scale, Offset translation) {
    final size = _size;
    final x = translation.dx.clamp(size.width * (1 - scale), 0.0);
    final y = translation.dy.clamp(size.height * (1 - scale), 0.0);
    return Matrix4.identity()
      ..translateByDouble(x, y, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _down(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      _animation.stop();
      _wheelTimer?.cancel();
      _multiple = false;
      widget.onContact?.call();
      widget.onActivityChanged?.call(true);
    }
    _pointers.add(event.pointer);
    if (_pointers.length > 1 && !_multiple) {
      _multiple = true;
      _drag?.cancel();
      _drag = null;
      widget.onPinch?.call();
    }
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) {
      widget.onActivityChanged?.call(false);
      widget.onZoomSettled?.call(_scale);
    }
  }

  void _start(ScaleStartDetails details) {
    _initial = widget.controller.value.clone();
    _origin = details.localFocalPoint;
    if (!_multiple && details.pointerCount == 1 && _scale <= 1.001) {
      _drag = widget.startScroll(
        DragStartDetails(
          globalPosition: details.focalPoint,
          localPosition: details.localFocalPoint,
        ),
      );
    }
  }

  void _update(ScaleUpdateDetails details) {
    final drag = _drag;
    if (drag != null && !_multiple) {
      final delta = widget.axis == Axis.horizontal
          ? Offset(details.focalPointDelta.dx, 0)
          : Offset(0, details.focalPointDelta.dy);
      drag.update(
        DragUpdateDetails(
          globalPosition: details.focalPoint,
          localPosition: details.localFocalPoint,
          delta: delta,
          primaryDelta: widget.axis == Axis.horizontal ? delta.dx : delta.dy,
        ),
      );
      return;
    }
    final initialScale = _initial.getMaxScaleOnAxis();
    final translation = _initial.getTranslation();
    final anchor =
        (_origin - Offset(translation.x, translation.y)) / initialScale;
    final scale = (initialScale * details.scale).clamp(1.0, 6.0);
    widget.controller.value = _matrix(
      scale,
      details.localFocalPoint - anchor * scale,
    );
  }

  void _end(ScaleEndDetails details) {
    final drag = _drag;
    _drag = null;
    final speed = widget.axis == Axis.horizontal
        ? Offset(details.velocity.pixelsPerSecond.dx, 0)
        : Offset(0, details.velocity.pixelsPerSecond.dy);
    drag?.end(
      DragEndDetails(
        velocity: Velocity(pixelsPerSecond: speed),
        primaryVelocity: widget.axis == Axis.horizontal ? speed.dx : speed.dy,
      ),
    );
  }

  Future<void> _toggleZoom() async {
    _animation.stop();
    final scale = _scale > 1.001 ? 1.0 : 2.0;
    final end = _matrix(scale, _doubleTap * (1 - scale));
    _matrixAnimation = Matrix4Tween(
      begin: widget.controller.value,
      end: end,
    ).animate(CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic));
    widget.onActivityChanged?.call(true);
    try {
      await _animation.forward(from: 0).orCancel;
      if (mounted) widget.onZoomSettled?.call(_scale);
    } on TickerCanceled {
      // A new contact takes over the current transform without a jump.
    } finally {
      if (!_disposed && mounted && _pointers.isEmpty) {
        widget.onActivityChanged?.call(false);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _wheelTimer?.cancel();
    _drag?.cancel();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerUp: _up,
    onPointerCancel: _up,
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent && event is! PointerScaleEvent) return;
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        final matrix = widget.controller.value;
        final t = matrix.getTranslation();
        if (event is PointerScaleEvent ||
            (event is PointerScrollEvent &&
                event.kind == PointerDeviceKind.mouse)) {
          final change = event is PointerScaleEvent
              ? event.scale
              : math.exp(-(event as PointerScrollEvent).scrollDelta.dy / 200);
          final anchor = (event.localPosition - Offset(t.x, t.y)) / _scale;
          final scale = (_scale * change).clamp(1.0, 6.0);
          _animation.stop();
          widget.onActivityChanged?.call(true);
          widget.controller.value = _matrix(
            scale,
            event.localPosition - anchor * scale,
          );
          _wheelTimer?.cancel();
          _wheelTimer = Timer(const Duration(milliseconds: 120), () {
            if (!mounted || _pointers.isNotEmpty) return;
            widget.onZoomSettled?.call(_scale);
            widget.onActivityChanged?.call(false);
          });
        } else if (event is PointerScrollEvent) {
          if (_scale > 1.001) {
            widget.controller.value = _matrix(
              _scale,
              Offset(t.x, t.y) - event.scrollDelta,
            );
          } else {
            final delta =
                widget.axis == Axis.horizontal && event.scrollDelta.dx != 0
                ? event.scrollDelta.dx
                : event.scrollDelta.dy;
            widget.onWheel?.call(delta);
          }
        }
      });
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: _start,
      onScaleUpdate: _update,
      onScaleEnd: _end,
      onTapUp: widget.onTap == null
          ? null
          : (details) {
              if (!_multiple) widget.onTap!(details.localPosition);
            },
      onDoubleTapDown: (details) => _doubleTap = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: widget.controller,
          child: RepaintBoundary(child: widget.child),
          builder: (context, child) =>
              Transform(transform: widget.controller.value, child: child),
        ),
      ),
    ),
  );
}
