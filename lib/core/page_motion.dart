/// Shared persisted presentation for comic and EPUB page turns.
class PageMotion {
  const PageMotion({
    this.duration = 380,
    this.followGesture = true,
    this.tint = .10,
    this.cornerRadius = 18,
  });
  final int duration;
  final bool followGesture;
  final double tint, cornerRadius;
  factory PageMotion.fromJson(Map<String, dynamic> data) {
    double value(String key, double fallback, double min, double max) {
      final v = data[key];
      return v is num && v.isFinite ? v.toDouble().clamp(min, max) : fallback;
    }

    return PageMotion(
      duration: value('animationDuration', 380, 150, 900).round(),
      followGesture: data['followGesture'] != false,
      tint: value('pageTint', .10, 0, .25),
      cornerRadius: value('pageCornerRadius', 18, 0, 32),
    );
  }
  Map<String, dynamic> toJson() => {
    'animationDuration': duration,
    'followGesture': followGesture,
    'pageTint': tint,
    'pageCornerRadius': cornerRadius,
  };
  PageMotion copy({
    int? duration,
    bool? followGesture,
    double? tint,
    double? cornerRadius,
  }) => PageMotion(
    duration: duration ?? this.duration,
    followGesture: followGesture ?? this.followGesture,
    tint: tint ?? this.tint,
    cornerRadius: cornerRadius ?? this.cornerRadius,
  );
}
