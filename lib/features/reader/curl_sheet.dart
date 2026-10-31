import 'dart:math' as math;

/// An inextensible sheet section: a broad front arc joins the tight roll with
/// continuous position and tangent. Units are logical pixels and radians.
/// The EPUB vertex shader uses the same section in its fold-aligned mesh.
class CurlSheet {
  CurlSheet(double width, double progress, {double cone = 1}) {
    final wave = math.sin(math.pi * progress.clamp(0, 1));
    radius = math.max(.001, width * .10 * wave * cone);
    angle = .60 * wave * cone;
    front = math.max(
      .001,
      width * (1 - progress) - radius * (math.pi - angle) / 2,
    );
  }
  late final double radius, angle, front;
  double get end => front + radius * (math.pi - angle);

  ({double x, double z, double angle}) point(double u) {
    if (u < 0) return (x: u, z: 0, angle: 0);
    final frontRadius = front / math.max(.00001, angle);
    final theta = angle * (u / front).clamp(0, 1);
    if (u <= front) {
      return (
        x: frontRadius * math.sin(theta),
        z: 2 * frontRadius * math.pow(math.sin(theta / 2), 2),
        angle: theta,
      );
    }
    final xf = frontRadius * math.sin(angle);
    final zf = 2 * frontRadius * math.pow(math.sin(angle / 2), 2);
    if (u <= end) {
      final roll = angle + (u - front) / radius;
      return (
        x: xf + radius * (math.sin(roll) - math.sin(angle)),
        z: zf + radius * (math.cos(angle) - math.cos(roll)),
        angle: roll,
      );
    }
    return (
      x: xf - radius * math.sin(angle) - (u - end),
      z: zf + radius * (1 + math.cos(angle)),
      angle: math.pi,
    );
  }
}
