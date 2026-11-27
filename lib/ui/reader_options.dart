import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../core/page_motion.dart';
import '../features/settings/settings_style.dart';
import 'common.dart';
import 'reader_chrome.dart';
import 'strings.dart';
import 'wheel_scroll.dart';

Future<void> showReaderOptions(BuildContext context, WidgetBuilder builder) {
  if (defaultTargetPlatform == TargetPlatform.windows &&
      MediaQuery.sizeOf(context).width >= 720) {
    return showGeneralDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200),
      pageBuilder: (context, _, _) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: SizedBox(
          width: 380,
          height: double.infinity,
          child: Material(elevation: 8, child: Builder(builder: builder)),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        textDirection: Directionality.of(context),
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(animation.drive(CurveTween(curve: Curves.easeOutCubic))),
        child: child,
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: readerSheetAnimation(context),
    showDragHandle: false,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => FractionallySizedBox(
      heightFactor: .82,
      child: Builder(builder: builder),
    ),
  );
}

/// A bounded reader form with a persistent title/close action on every screen.
class ReaderOptionsPanel extends StatelessWidget {
  const ReaderOptionsPanel({
    super.key,
    required this.title,
    required this.children,
    this.onClose,
    this.fill = false,
    this.useAppPalette = false,
    this.compact = false,
  });
  final String title;
  final List<Widget> children;
  final VoidCallback? onClose;
  final bool fill, useAppPalette, compact;
  @override
  Widget build(BuildContext context) {
    final app = Theme.of(context);
    final theme = useAppPalette ? app : settingsTheme(app);
    // Each control is a separate sliver child. A long text section must not
    // build, lay out and repaint as one enormous card on Android.
    final rows = <Widget>[];
    for (final child in children) {
      if (child is! ReaderOptionGroup) {
        rows.add(child);
        continue;
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Text(
            tr(context, child.title),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      );
      for (var i = 0; i < child.children.length; i++) {
        rows.add(
          Material(
            color: theme.cardColor,
            borderRadius: BorderRadius.vertical(
              top: i == 0 ? const Radius.circular(16) : Radius.zero,
              bottom: i == child.children.length - 1
                  ? const Radius.circular(16)
                  : Radius.zero,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (i > 0) const Divider(height: 1, indent: 18, endIndent: 18),
                child.children[i],
              ],
            ),
          ),
        );
      }
      rows.add(SizedBox(height: compact ? 10 : 22));
    }
    return Theme(
      data: theme,
      child: Material(
        color: theme.scaffoldBackgroundColor,
        child: SizedBox(
          height: fill
              ? null
              : math.min(820, MediaQuery.sizeOf(context).height * .88),
          child: Column(
            children: [
              Padding(
                padding: compact
                    ? const EdgeInsets.fromLTRB(16, 0, 4, 0)
                    : const EdgeInsets.fromLTRB(22, 12, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr(context, title),
                        style:
                            (compact
                                    ? app.textTheme.titleSmall
                                    : app.textTheme.titleLarge)
                                ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: tr(context, 'Close'),
                      onPressed: onClose ?? () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  scrollCacheExtent: const ScrollCacheExtent.pixels(120),
                  itemCount: rows.length,
                  itemBuilder: (_, index) => rows[index],
                  padding: compact
                      ? const EdgeInsets.fromLTRB(12, 4, 12, 16)
                      : const EdgeInsets.fromLTRB(20, 20, 20, 28),
                ).withWheelScrolling(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ReaderOptionGroup extends StatelessWidget {
  const ReaderOptionGroup({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            tr(context, title),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 18, endIndent: 18),
                children[i],
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class ReaderOptionPicker extends StatelessWidget {
  const ReaderOptionPicker({
    super.key,
    required this.title,
    required this.value,
    required this.choices,
    required this.onChanged,
  });
  final String title, value;
  final Map<String, String> choices;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => Builder(
      builder: (row) => InkWell(
        onTap: () async {
          final result = await chooseValue<String>(
            row,
            title: title,
            selected: value,
            choices: choices,
            anchored: true,
          );
          if (result != null && row.mounted) onChanged(result);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr(context, title),
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(width: 16),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: bounds.maxWidth * .42),
                child: Text(
                  tr(context, choices[value] ?? value),
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.unfold_more, size: 18),
            ],
          ),
        ),
      ),
    ),
  );
}

class ReaderOptionSlider extends StatefulWidget {
  const ReaderOptionSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.label,
    this.formatValue,
    this.divisions,
  });
  final String title;
  final double value, min, max;
  final String? label;
  final String Function(double)? formatValue;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  @override
  State<ReaderOptionSlider> createState() => _ReaderOptionSliderState();
}

class _ReaderOptionSliderState extends State<ReaderOptionSlider> {
  late double draft = widget.value;
  @override
  void didUpdateWidget(ReaderOptionSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) draft = widget.value;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr(context, widget.title),
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              widget.label ??
                  widget.formatValue?.call(draft) ??
                  draft.toStringAsFixed(2),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        Slider(
          value: draft.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: (v) {
            setState(() => draft = v);
            widget.onChanged(v);
          },
          onChangeEnd: widget.onChangeEnd,
        ),
      ],
    ),
  );
}

class ReaderMotionOptions extends StatefulWidget {
  const ReaderMotionOptions({
    super.key,
    required this.motion,
    required this.onChanged,
  });
  final PageMotion motion;
  final ValueChanged<PageMotion> onChanged;
  @override
  State<ReaderMotionOptions> createState() => _ReaderMotionOptionsState();
}

class _ReaderMotionOptionsState extends State<ReaderMotionOptions> {
  late PageMotion draft = widget.motion;
  @override
  void didUpdateWidget(ReaderMotionOptions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.motion != widget.motion) draft = widget.motion;
  }

  void commit() => widget.onChanged(draft);
  @override
  Widget build(BuildContext context) => Column(
    children: [
      SwitchListTile.adaptive(
        title: Text(tr(context, 'motion.followGesture')),
        subtitle: Text(tr(context, 'motion.followGesture.caption')),
        value: draft.followGesture,
        onChanged: (v) {
          setState(() => draft = draft.copy(followGesture: v));
          commit();
        },
      ),
      ReaderOptionSlider(
        title: 'motion.duration',
        value: draft.duration.toDouble(),
        min: 150,
        max: 900,
        divisions: 75,
        label: '${draft.duration} ms',
        onChanged: (v) =>
            setState(() => draft = draft.copy(duration: v.round())),
        onChangeEnd: (_) => commit(),
      ),
    ],
  );
}
