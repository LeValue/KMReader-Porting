import '../../core/models.dart';

enum TapAction { previous, controls, next }

/// Matches upstream TapZoneHelper, including the narrow T-split top strip.
TapAction tapAction(double x, double y, ReaderPreferences preferences) {
  final mode = preferences.tapMode;
  if (mode == 'none') return TapAction.controls;
  final inverted =
      preferences.tapInversion == 'inverted' ||
      preferences.tapInversion == 'auto' &&
          preferences.direction == ReadingDirection.rtl;
  if (mode == 'tSplit') {
    if (y <= .12) return TapAction.controls;
    return (x < .5) != inverted ? TapAction.previous : TapAction.next;
  }
  var column = (x.clamp(0, .999999) * 3).floor();
  final row = (y.clamp(0, .999999) * 3).floor();
  if (inverted) column = 2 - column;
  switch (mode) {
    case 'edge':
      return row == 1 && column == 1
          ? TapAction.controls
          : row == 2 && column == 1
          ? TapAction.previous
          : TapAction.next;
    case 'kindle':
      return row == 0
          ? TapAction.controls
          : column == 0
          ? TapAction.previous
          : TapAction.next;
    case 'lShape':
      return row == 1 && column == 1
          ? TapAction.controls
          : row == 0 || row == 1 && column == 0
          ? TapAction.previous
          : TapAction.next;
    default:
      return column == 0
          ? TapAction.previous
          : column == 1
          ? TapAction.controls
          : TapAction.next;
  }
}

({int before, int after}) preloadWindow(String profile) => switch (profile) {
  'lowMemory' => (before: 1, after: 3),
  'fastPageTurns' => (before: 5, after: 7),
  _ => (before: 3, after: 5),
};
