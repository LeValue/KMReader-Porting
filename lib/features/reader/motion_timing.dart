import 'package:flutter/widgets.dart';

/// No wall-clock catch-up jump after a late frame. The first delivered frame is
/// the origin; pointer motion stays direct and only automatic settling is paced.
class ReaderMotionSimulation extends Simulation {
  ReaderMotionSimulation(
    this.from,
    this.to,
    Duration duration, {
    this.velocity = 0,
    this.automatic = true,
  }) : seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
  final double from, to, seconds, velocity;
  final bool automatic;
  double? _last;
  double _elapsed = 0;
  @override
  double x(double time) {
    if (_last != null) _elapsed += (time - _last!).clamp(0, .032);
    _last = time;
    final t = (_elapsed / seconds).clamp(0.0, 1.0);
    final delta = to - from;
    final tangent = delta == 0
        ? 0.0
        : (velocity * seconds / delta).clamp(0.0, 3.0);
    final eased = automatic
        ? readerEase.transform(t)
        : -2 * t * t * t + 3 * t * t + tangent * (t * t * t - 2 * t * t + t);
    return from + delta * eased;
  }

  @override
  double dx(double time) {
    final t = (_elapsed / seconds).clamp(0.0, 1.0), delta = to - from;
    final tangent = delta == 0
        ? 0.0
        : (velocity * seconds / delta).clamp(0.0, 3.0);
    return delta /
        seconds *
        (automatic
            ? 30 * t * t * (1 - t) * (1 - t)
            : -6 * t * t + 6 * t + tangent * (3 * t * t - 4 * t + 1));
  }

  @override
  bool isDone(double time) => _elapsed >= seconds;
}

class _ReaderEase extends Curve {
  const _ReaderEase();
  @override
  double transformInternal(double t) => t * t * t * (10 + t * (-15 + 6 * t));
}

const Curve readerEase = _ReaderEase();

/// Keep PageView's native spring and velocity, but avoid catching up a stalled
/// render thread in a single large scroll-position jump after release.
class PacedReaderSimulation extends Simulation {
  PacedReaderSimulation(this.source);
  final Simulation source;
  double? _last;
  double _time = 0;
  @override
  double x(double time) {
    if (_last != null) _time += (time - _last!).clamp(0, .032);
    _last = time;
    return source.x(_time);
  }

  @override
  double dx(double time) => source.dx(_time);
  @override
  bool isDone(double time) => source.isDone(_time);
}

class ReaderPagePhysics extends PageScrollPhysics {
  const ReaderPagePhysics({super.parent, this.isAnimating});
  final bool Function()? isAnimating;
  @override
  ReaderPagePhysics applyTo(ScrollPhysics? ancestor) => ReaderPagePhysics(
    parent: buildParent(ancestor),
    isAnimating: isAnimating,
  );
  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // A programmatic frame already owns the offset. jumpTo must not launch a
    // competing snap spring between its next two delivered frames.
    if (isAnimating?.call() ?? false) return null;
    final source = super.createBallisticSimulation(position, velocity);
    return source == null ? null : PacedReaderSimulation(source);
  }
}
