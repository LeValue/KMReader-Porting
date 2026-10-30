import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart' show Ticker;

/// Animate Windows wheel detents through the existing scroll activity. Touch,
/// trackpad pan gestures, scrollbar dragging and programmatic jumps stay native.
class AppScrollController extends ScrollController {
  AppScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    if (Theme.of(context.storageContext).platform != TargetPlatform.windows) {
      return super.createScrollPosition(physics, context, oldPosition);
    }
    return _WheelScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _WheelScrollPosition extends ScrollPositionWithSingleContext {
  _WheelScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  // Critical damping gives a continuous velocity without a bounce. Limit the
  // carried velocity as the target approaches a boundary to prevent overshoot.
  static const _frequency = 30.0;
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: _frequency * _frequency,
    damping: 2 * _frequency,
  );
  double? _wheelTarget;

  @override
  void absorb(ScrollPosition other) {
    super.absorb(other);
    if (other is _WheelScrollPosition && activity is _WheelScrollActivity) {
      _wheelTarget = other._wheelTarget;
    }
  }

  bool get _reducedMotion =>
      MediaQuery.maybeOf(context.storageContext)?.disableAnimations ?? false;

  @override
  void pointerScroll(double delta) {
    if (delta == 0 || _reducedMotion) {
      super.pointerScroll(delta);
      return;
    }
    final remaining = (_wheelTarget ?? pixels) - pixels;
    final continuing =
        activity is _WheelScrollActivity && remaining.sign == delta.sign;
    final target = ((continuing ? _wheelTarget! : pixels) + delta)
        .clamp(minScrollExtent, maxScrollExtent)
        .toDouble();
    final velocity = continuing ? activity!.velocity : 0.0;
    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    _animateWheel(target, velocity);
  }

  void _animateWheel(double target, double velocity) {
    target = target.clamp(minScrollExtent, maxScrollExtent).toDouble();
    final distance = target - pixels;
    if (distance == 0 || _reducedMotion) {
      goIdle();
      if (distance != 0) jumpTo(target);
      return;
    }
    final speed = velocity.sign == distance.sign
        ? math.min(velocity.abs(), _frequency * distance.abs()) * distance.sign
        : 0.0;
    _wheelTarget = target;
    final simulation = ScrollSpringSimulation(
      _spring,
      pixels,
      target,
      speed,
      tolerance: const Tolerance(distance: .1, velocity: 1),
    );
    final current = activity;
    if (current is _WheelScrollActivity) {
      current.retarget(simulation);
    } else {
      beginActivity(_WheelScrollActivity(this, simulation, context.vsync));
    }
  }

  void _dimensionsChanged(double velocity) {
    final target = _wheelTarget;
    if (target != null) _animateWheel(target, velocity);
  }

  @override
  void beginActivity(ScrollActivity? newActivity) {
    if (newActivity is! _WheelScrollActivity) _wheelTarget = null;
    super.beginActivity(newActivity);
  }
}

class _WheelScrollActivity extends ScrollActivity {
  _WheelScrollActivity(super.delegate, this._simulation, TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick)..start();
  }

  late final Ticker _ticker;
  Simulation _simulation;
  Duration _lastTick = Duration.zero, _simulationStart = Duration.zero;
  bool _disposed = false;

  double get _time =>
      (_lastTick - _simulationStart).inMicroseconds /
      Duration.microsecondsPerSecond;

  // Keep one ticker for the entire wheel sequence. Restarting an animation on
  // every detent would repeatedly render its initial frame and can stall under
  // high-rate input. Rebase the simulation at the last rendered position/time.
  void retarget(Simulation simulation) {
    _simulation = simulation;
    _simulationStart = _lastTick;
  }

  void _tick(Duration elapsed) {
    _lastTick = elapsed;
    final overflow = delegate.setPixels(_simulation.x(_time));
    if (!_disposed && (overflow != 0 || _simulation.isDone(_time))) {
      delegate.goIdle();
    }
  }

  @override
  bool get shouldIgnorePointer => false;
  @override
  bool get isScrolling => true;
  @override
  double get velocity => _simulation.dx(_time);

  @override
  void applyNewDimensions() =>
      (delegate as _WheelScrollPosition)._dimensionsChanged(velocity);

  @override
  void resetActivity() => applyNewDimensions();

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    super.dispose();
  }
}

/// Give an implicit scroll view its own controller without sharing positions
/// between tabs or nested lists. The child still decides how to build its items.
class WheelScrollScope extends StatefulWidget {
  const WheelScrollScope({
    super.key,
    this.axis = Axis.vertical,
    required this.child,
  });
  final Axis axis;
  final Widget child;

  @override
  State<WheelScrollScope> createState() => _WheelScrollScopeState();
}

class _WheelScrollScopeState extends State<WheelScrollScope> {
  AppScrollController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return widget.child;
    }
    return PrimaryScrollController(
      controller: _controller ??= AppScrollController(),
      automaticallyInheritForPlatforms: const {TargetPlatform.windows},
      scrollDirection: widget.axis,
      child: widget.child,
    );
  }
}

extension WheelScrolling on Widget {
  Widget withWheelScrolling({Axis axis = Axis.vertical}) =>
      WheelScrollScope(axis: axis, child: this);
}
