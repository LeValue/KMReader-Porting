import 'package:flutter/material.dart';

/// Keep native Android/Windows scroll boundaries visually stationary, including
/// dialogs, settings routes and other scrollables outside the main dashboard.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics(parent: RangeMaintainingScrollPhysics());
}
