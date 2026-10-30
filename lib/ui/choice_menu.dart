import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import 'wheel_scroll.dart';

/// A tall menu fades as one retained surface instead of resizing and laying out
/// every row on each closing frame. Its result is delivered after removal.
Future<T?> showChoiceMenu<T>(
  BuildContext context, {
  required Rect anchor,
  required T selected,
  required Map<T, String> labels,
}) async {
  final navigator = Navigator.of(context);
  final theme = Theme.of(context);
  final textStyle =
      theme.popupMenuTheme.textStyle ?? theme.textTheme.bodyLarge!;
  final maximum = math.min(420.0, navigator.overlay!.context.size!.width - 16);
  var width = math.min(220.0, maximum);
  for (final label in labels.values) {
    final text = TextPainter(
      text: TextSpan(text: label, style: textStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: math.max(1, maximum - 80));
    width = math.max(width, math.min(maximum, text.width + 80));
    text.dispose();
  }
  final route = _ChoiceMenuRoute<T>(
    anchor: anchor,
    selected: selected,
    labels: labels,
    width: width,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    label: MaterialLocalizations.of(context).popupMenuLabel,
    dismissLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    reducedMotion: MediaQuery.disableAnimationsOf(context),
  );
  final value = await navigator.push<T>(route);
  await route.completed;
  return value;
}

class _ChoiceMenuRoute<T> extends PopupRoute<T> {
  _ChoiceMenuRoute({
    required this.anchor,
    required this.selected,
    required this.labels,
    required this.width,
    required this.themes,
    required this.label,
    required this.dismissLabel,
    required this.reducedMotion,
  });
  final Rect anchor;
  final T selected;
  final Map<T, String> labels;
  final double width;
  final CapturedThemes themes;
  final String label, dismissLabel;
  final bool reducedMotion;
  final _selected = GlobalKey();
  final _scroll = AppScrollController();
  bool _scheduledSelection = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String get barrierLabel => dismissLabel;
  @override
  Duration get transitionDuration =>
      reducedMotion ? Duration.zero : const Duration(milliseconds: 160);
  @override
  Duration get reverseTransitionDuration =>
      reducedMotion ? Duration.zero : const Duration(milliseconds: 120);
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    if (!_scheduledSelection) {
      _scheduledSelection = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final selectedContext = _selected.currentContext;
        if (selectedContext != null) {
          Scrollable.ensureVisible(selectedContext, alignment: .5);
        }
      });
    }
    return themes.wrap(
      Builder(
        builder: (context) {
          final theme = Theme.of(context), menu = theme.popupMenuTheme;
          return CustomSingleChildLayout(
            delegate: _ChoiceMenuLayout(
              anchor,
              width,
              MediaQuery.paddingOf(context),
            ),
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              role: SemanticsRole.menu,
              label: label,
              child: RepaintBoundary(
                child: Material(
                  color: menu.color ?? theme.colorScheme.surface,
                  surfaceTintColor: menu.surfaceTintColor,
                  elevation: menu.elevation ?? 6,
                  shape:
                      menu.shape ??
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                  clipBehavior: Clip.antiAlias,
                  child: DefaultTextStyle(
                    style: menu.textStyle ?? theme.textTheme.bodyLarge!,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      primary: false,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in labels.entries)
                            KeyedSubtree(
                              key: entry.key == selected ? _selected : null,
                              child: CheckedPopupMenuItem<T>(
                                value: entry.key,
                                checked: entry.key == selected,
                                child: Text(entry.value),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: animation.drive(CurveTween(curve: Curves.easeInOut)),
    child: child,
  );
}

class _ChoiceMenuLayout extends SingleChildLayoutDelegate {
  const _ChoiceMenuLayout(this.anchor, this.width, this.padding);
  final Rect anchor;
  final double width;
  final EdgeInsets padding;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(
        width: math.min(width, constraints.maxWidth - padding.horizontal - 16),
      ).copyWith(
        minHeight: 0,
        maxHeight: math.max(
          0,
          (constraints.maxHeight - padding.vertical - 16) * .85,
        ),
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (anchor.right - childSize.width).clamp(
      padding.left + 8,
      math.max(
        padding.left + 8,
        size.width - padding.right - childSize.width - 8,
      ),
    );
    var top = anchor.bottom + 4;
    if (top + childSize.height > size.height - padding.bottom - 8 &&
        anchor.top - childSize.height - 4 >= padding.top + 8) {
      top = anchor.top - childSize.height - 4;
    }
    return Offset(
      left.toDouble(),
      top.clamp(
        padding.top + 8,
        math.max(
          padding.top + 8,
          size.height - padding.bottom - childSize.height - 8,
        ),
      ),
    );
  }

  @override
  bool shouldRelayout(_ChoiceMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      width != oldDelegate.width ||
      padding != oldDelegate.padding;
}
