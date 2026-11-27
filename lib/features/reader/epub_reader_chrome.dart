import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../ui/strings.dart';

class EpubToolbarLayout extends StatelessWidget {
  const EpubToolbarLayout({
    super.key,
    required this.leading,
    required this.center,
    required this.trailing,
  });

  final Widget leading, center, trailing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => Row(
      children: [
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: leading,
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: bounds.maxWidth / 2),
          child: center,
        ),
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: trailing,
          ),
        ),
      ],
    ),
  );
}

class EpubDesktopPanels extends StatefulWidget {
  const EpubDesktopPanels({
    super.key,
    required this.reader,
    required this.panel,
    required this.capture,
    required this.settle,
  });

  final Widget Function(Widget? pageCover) reader;
  final Widget? panel;
  final Future<(ui.Image, int)?> Function() capture;
  final Future<void> Function(int previousViewportWidth) settle;

  @override
  State<EpubDesktopPanels> createState() => _EpubDesktopPanelsState();
}

class _EpubDesktopPanelsState extends State<EpubDesktopPanels>
    with TickerProviderStateMixin {
  late final _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 230),
    value: widget.panel == null ? 0 : 1,
  );
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    value: 1,
  );
  late bool _layoutOpen = widget.panel != null;
  late Widget? _retainedPanel = widget.panel;
  ui.Image? _page;
  double _pageWidth = 0, _viewportWidth = 0;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _slide.value = widget.panel == null ? 0 : 1;
  }

  @override
  void didUpdateWidget(EpubDesktopPanels oldWidget) {
    super.didUpdateWidget(oldWidget);
    final panel = widget.panel;
    if (panel != null) _retainedPanel = panel;
    if ((oldWidget.panel == null) != (panel == null)) {
      unawaited(_transition(panel != null));
    }
  }

  Future<void> _transition(bool open) async {
    final request = ++_request;
    bool current() => mounted && request == _request;
    final animate = !MediaQuery.disableAnimationsOf(context);
    try {
      final oldWidth = _viewportWidth;
      final frame = animate && _layoutOpen != open
          ? await widget.capture()
          : null;
      if (!current()) {
        frame?.$1.dispose();
        return;
      }
      final previousPage = _page;
      setState(() {
        _page = frame?.$1;
        _pageWidth = oldWidth;
        _layoutOpen = open;
      });
      previousPage?.dispose();
      _fade.value = frame == null ? 1 : 0;
      if (!animate) _slide.value = open ? 1 : 0;
      // Resize once, concurrently with the panel. The frozen image covers the
      // still-visible edge until the sidebar reaches it.
      final moving = animate ? _slide.animateTo(open ? 1 : 0) : null;
      if (frame != null) {
        // The live WebView reflows behind its own last rendered frame.
        await WidgetsBinding.instance.endOfFrame;
        if (!current()) return;
        await widget.settle(frame.$2);
        if (!current()) return;
        await _fade.forward().orCancel;
      }
      await moving?.orCancel;
      if (!current()) return;
      setState(() {
        _page?.dispose();
        _page = null;
        if (!open) _retainedPanel = null;
      });
    } on TickerCanceled {
      // Reversing or disposing an interrupted transition cancels its ticker.
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    _fade.dispose();
    _page?.dispose();
    super.dispose();
  }

  Widget? _cover() {
    final page = _page;
    if (page == null) return null;
    Widget snapshot(Alignment alignment) => ClipRect(
      child: OverflowBox(
        alignment: alignment,
        minWidth: _pageWidth,
        maxWidth: _pageWidth,
        child: RawImage(image: page, fit: BoxFit.fill),
      ),
    );
    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: FadeTransition(
              opacity: ReverseAnimation(_fade),
              child: snapshot(Alignment.topLeft),
            ),
          ),
          if (_pageWidth > _viewportWidth)
            Positioned(
              left: _viewportWidth,
              width: _pageWidth - _viewportWidth,
              top: 0,
              bottom: 0,
              child: snapshot(Alignment.topRight),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.min(352.0, constraints.maxWidth * .48);
      final inset = _layoutOpen ? width : 0.0;
      _viewportWidth = constraints.maxWidth - inset;
      return ClipRect(
        child: Stack(
          children: [
            Positioned.fill(right: inset, child: widget.reader(_cover())),
            if (_retainedPanel case final Widget panel)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: width,
                child: SlideTransition(
                  position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                      .chain(CurveTween(curve: Curves.easeInOutCubic))
                      .animate(_slide),
                  child: IgnorePointer(
                    ignoring: widget.panel == null,
                    child: panel,
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class EpubSelectionMenu extends StatelessWidget {
  const EpubSelectionMenu({
    super.key,
    required this.anchor,
    required this.actions,
    this.touch = false,
  });

  final Rect anchor;
  final List<({String label, IconData icon, VoidCallback invoke})> actions;
  final bool touch;

  @override
  Widget build(BuildContext context) => CustomSingleChildLayout(
    delegate: _SelectionPosition(anchor, touch),
    child: Semantics(
      container: true,
      explicitChildNodes: true,
      label: tr(context, 'Selected text actions'),
      child: Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(touch ? 3 : 6),
          child: LayoutBuilder(
            builder: (context, bounds) {
              final iconsOnly = touch && bounds.maxWidth < 460;
              return Wrap(
                spacing: 2,
                runSpacing: 2,
                children: [
                  for (final action in actions)
                    if (iconsOnly)
                      IconButton(
                        tooltip: tr(context, action.label),
                        onPressed: action.invoke,
                        icon: Icon(action.icon, size: 20),
                      )
                    else
                      TextButton.icon(
                        onPressed: action.invoke,
                        icon: Icon(action.icon, size: 18),
                        label: Text(tr(context, action.label)),
                      ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class EpubAnnotationTile extends StatelessWidget {
  const EpubAnnotationTile({
    super.key,
    required this.icon,
    required this.label,
    required this.chapter,
    required this.body,
    required this.selected,
    required this.open,
    this.delete,
    this.noteLabel,
    this.openNote,
    this.accent,
  });

  final IconData icon;
  final String label, chapter, body;
  final bool selected;
  final VoidCallback open;
  final VoidCallback? delete, openNote;
  final String? noteLabel;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: selected
          ? Color.alphaBlend(
              colors.primary.withValues(alpha: .10),
              colors.surface,
            )
          : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.hardEdge,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: accent == null
              ? null
              : BorderDirectional(start: BorderSide(color: accent!, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Semantics(
                    selected: selected,
                    child: InkWell(
                      onTap: open,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 9, 8, 7),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              icon,
                              size: 17,
                              color: accent ?? colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    label,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                  ),
                                  if (chapter.isNotEmpty)
                                    Text(
                                      chapter,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                  if (body.isNotEmpty) ...[
                                    const SizedBox(height: 5),
                                    Text(
                                      body,
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (delete != null)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (_) => delete!(),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(tr(context, 'Delete')),
                      ),
                    ],
                  ),
              ],
            ),
            if (noteLabel != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 8, 5),
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    alignment: AlignmentDirectional.centerStart,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: openNote,
                  icon: const Icon(Icons.edit_note, size: 19),
                  label: Text(
                    noteLabel!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class EpubAnnotationFilterGrid<T> extends StatelessWidget {
  const EpubAnnotationFilterGrid({
    super.key,
    required this.options,
    required this.selected,
    required this.select,
  });

  final List<({T value, String label, Color? color})> options;
  final T selected;
  final ValueChanged<T> select;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      const gap = 6.0;
      final columns = bounds.maxWidth < 190
          ? 1
          : bounds.maxWidth >= 560
          ? 4
          : 2;
      final width = (bounds.maxWidth - (columns - 1) * gap) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final option in options)
            SizedBox(
              width: width,
              child: ChoiceChip(
                avatar: option.color == null
                    ? null
                    : Icon(Icons.circle, size: 10, color: option.color),
                label: Text(
                  option.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: selected == option.value,
                showCheckmark: false,
                onSelected: (_) => select(option.value),
              ),
            ),
        ],
      );
    },
  );
}

class _SelectionPosition extends SingleChildLayoutDelegate {
  const _SelectionPosition(this.anchor, this.touch);
  final Rect anchor;
  final bool touch;
  static const gap = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.max(
            0,
            math.min(touch ? 540 : 440, constraints.maxWidth - gap * 2),
          ),
          math.max(0, constraints.maxHeight - gap * 2),
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rect = Rect.fromLTRB(
      anchor.left * size.width,
      anchor.top * size.height,
      anchor.right * size.width,
      anchor.bottom * size.height,
    );
    final x = (rect.center.dx - childSize.width / 2).clamp(
      gap,
      math.max(gap, size.width - childSize.width - gap),
    );
    final below = rect.bottom + (touch ? 26 : gap);
    final above = rect.top - childSize.height - gap;
    final fitsBelow = below + childSize.height <= size.height - gap;
    final y = (touch && above >= gap || !fitsBelow ? above : below).clamp(
      gap,
      math.max(gap, size.height - childSize.height - gap),
    );
    return Offset(x.toDouble(), y.toDouble());
  }

  @override
  bool shouldRelayout(_SelectionPosition oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.touch != touch;
}

class EpubPanelHeader extends StatelessWidget {
  const EpubPanelHeader({
    super.key,
    required this.title,
    required this.close,
    this.trailing,
  });

  final String title;
  final VoidCallback close;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                tr(context, title),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ?trailing,
            IconButton(
              tooltip: tr(context, 'Close'),
              onPressed: close,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
    ],
  );
}
