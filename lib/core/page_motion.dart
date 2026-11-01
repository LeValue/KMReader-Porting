/// Persisted input and timing for comic and EPUB page turns.
/// Legacy cosmetic overrides are deliberately ignored during migration.
class PageMotion {
  const PageMotion({this.duration = 380, this.followGesture = true});
  final int duration;
  final bool followGesture;
  factory PageMotion.fromJson(Map<String, dynamic> data) {
    final value = data['animationDuration'];
    return PageMotion(
      duration: value is num && value.isFinite
          ? value.round().clamp(150, 900)
          : 380,
      followGesture: data['followGesture'] != false,
    );
  }
  Map<String, dynamic> toJson() => {
    'animationDuration': duration,
    'followGesture': followGesture,
  };
  PageMotion copy({int? duration, bool? followGesture}) => PageMotion(
    duration: duration ?? this.duration,
    followGesture: followGesture ?? this.followGesture,
  );
}
