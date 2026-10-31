import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'reader_viewport.dart';

/// A wide spread fills the height. One gesture either pans its contents or,
/// when starting at the outer edge, turns the page. Pinching cancels either drag.
class WidePage extends StatefulWidget {
  const WidePage({
    super.key,
    required this.aspect,
    required this.rtl,
    required this.child,
    required this.startPageScroll,
    this.onTap,
    this.onTapKind,
    this.onControls,
    this.onZoomSettled,
    this.active = true,
    this.doubleTapZoom = 2,
    this.initialFraction = 0,
    this.onPanSettled,
  });
  final double aspect, doubleTapZoom, initialFraction;
  final ValueChanged<double>? onPanSettled;
  final bool rtl, active;
  final Widget child;
  final Drag? Function(DragStartDetails) startPageScroll;
  final void Function(Offset, Size)? onTap;
  final VoidCallback? onControls;
  final ValueChanged<PointerDeviceKind>? onTapKind;
  final ValueChanged<double>? onZoomSettled;
  @override
  State<WidePage> createState() => _WidePageState();
}

class _WidePageState extends State<WidePage> {
  final _scroll = ScrollController(keepScrollOffset: false);
  final _zoom = TransformationController();
  double _gestureStart = 0;
  bool _restorePending = true, _panning = false, _cancelledPan = false;
  double? _restoreFraction, _lastFraction;
  Size? _size;
  void _restore() {
    if (!_restorePending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_restorePending ||
          !_scroll.hasClients ||
          !_scroll.position.hasContentDimensions) {
        return;
      }
      final fraction = (_restoreFraction ?? widget.initialFraction);
      _restorePending = false;
      _restoreFraction = null;
      _lastFraction = fraction.isFinite ? fraction.clamp(0, 1) : 0;
      _scroll.jumpTo(_scroll.position.maxScrollExtent * _lastFraction!);
    });
  }

  bool _notification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _panning = true;
    }
    if (notification is ScrollEndNotification && _panning) {
      _panning = false;
      if (!_cancelledPan &&
          !_restorePending &&
          _scroll.hasClients &&
          _scroll.position.maxScrollExtent > 0) {
        _lastFraction = (_scroll.offset / _scroll.position.maxScrollExtent)
            .clamp(0, 1);
        widget.onPanSettled?.call(_lastFraction!);
      }
    }
    return false;
  }

  @override
  void didUpdateWidget(WidePage old) {
    super.didUpdateWidget(old);
    if (!old.active && widget.active) {
      _restorePending = true;
      _restoreFraction = widget.initialFraction;
    }
    if (old.active && !widget.active ||
        old.rtl != widget.rtl ||
        old.aspect != widget.aspect) {
      _zoom.value = Matrix4.identity();
      _cancelledPan = true;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _restorePending = widget.active;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_size != null && _size != constraints.biggest && _scroll.hasClients) {
        _restoreFraction = _scroll.position.maxScrollExtent > 0
            ? (_scroll.offset / _scroll.position.maxScrollExtent).clamp(0, 1)
            : _lastFraction ?? widget.initialFraction;
        _restorePending = true;
        _cancelledPan = true;
      }
      _size = constraints.biggest;
      _restore();
      final width = math.max(
        constraints.maxWidth,
        constraints.maxHeight * widget.aspect,
      );
      return ReaderViewport(
        controller: _zoom,
        doubleTapZoom: widget.doubleTapZoom,
        onContact: () {
          _gestureStart = _scroll.hasClients ? _scroll.offset : 0;
          _cancelledPan = false;
        },
        onPinch: () {
          _cancelledPan = true;
          if (_scroll.hasClients) _scroll.jumpTo(_gestureStart);
        },
        onZoomSettled: widget.onZoomSettled,
        onTapKind: widget.onTapKind,
        onTap: (point) {
          if (_zoom.value.getMaxScaleOnAxis() > 1.001) {
            widget.onControls?.call();
          } else {
            widget.onTap?.call(point, constraints.biggest);
          }
        },
        onWheel: (delta) {
          if (!_scroll.hasClients) return;
          final position = _scroll.position;
          final next = (position.pixels + delta).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          position.jumpTo(next);
        },
        startScroll: (details) =>
            _EdgeDrag(details, _scroll.position, widget.startPageScroll),
        child: NotificationListener<ScrollNotification>(
          onNotification: _notification,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            reverse: widget.rtl,
            physics: const NeverScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            child: SizedBox(
              width: width,
              height: constraints.maxHeight,
              child: widget.child,
            ),
          ),
        ),
      );
    },
  );
}

class _EdgeDrag implements Drag {
  _EdgeDrag(this.start, this.content, this.page);
  final DragStartDetails start;
  final ScrollPosition content;
  final Drag? Function(DragStartDetails) page;
  Drag? _owner;
  bool _chosen = false;
  @override
  void update(DragUpdateDetails details) {
    if (!_chosen) {
      final delta =
          details.delta.dx *
          (content.axisDirection == AxisDirection.left ? -1 : 1);
      if (delta.abs() < .001) return;
      final canPan = delta < 0
          ? content.pixels < content.maxScrollExtent - .5
          : content.pixels > content.minScrollExtent + .5;
      _owner = canPan ? content.drag(start, () {}) : page(start);
      _chosen = true;
    }
    _owner?.update(details);
  }

  @override
  void end(DragEndDetails details) {
    _owner?.end(details);
  }

  @override
  void cancel() {
    _owner?.cancel();
  }
}
