import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../ui/strings.dart';

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
      // Opening slides over the original publication. The WebView receives a
      // single new width after the panel arrives, preserving the CFI once.
      if (open && animate) await _slide.forward().orCancel;
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
      final closing = !open && animate ? _slide.reverse() : null;
      if (frame != null) {
        // The live WebView reflows behind its own last rendered frame.
        await WidgetsBinding.instance.endOfFrame;
        if (!current()) return;
        await widget.settle(frame.$2);
        if (!current()) return;
        await _fade.forward().orCancel;
      }
      await closing?.orCancel;
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

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.min(352.0, constraints.maxWidth * .48);
      final inset = _layoutOpen ? width : 0.0;
      _viewportWidth = constraints.maxWidth - inset;
      return Stack(
        children: [
          Positioned.fill(
            right: inset,
            child: widget.reader(
              _page == null
                  ? null
                  : IgnorePointer(
                      child: FadeTransition(
                        opacity: ReverseAnimation(_fade),
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: _pageWidth,
                            maxWidth: _pageWidth,
                            child: RawImage(image: _page, fit: BoxFit.fill),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
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
      );
    },
  );
}

class EpubSelectionMenu extends StatelessWidget {
  const EpubSelectionMenu({
    super.key,
    required this.anchor,
    required this.actions,
  });

  final Rect anchor;
  final List<({String label, IconData icon, VoidCallback invoke})> actions;

  @override
  Widget build(BuildContext context) => CustomSingleChildLayout(
    delegate: _SelectionPosition(anchor),
    child: Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(6),
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (final action in actions)
              TextButton.icon(
                onPressed: action.invoke,
                icon: Icon(action.icon, size: 18),
                label: Text(tr(context, action.label)),
              ),
          ],
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
  });

  final IconData icon;
  final String label, chapter, body;
  final bool selected;
  final VoidCallback open;
  final VoidCallback? delete, openNote;
  final String? noteLabel;

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
          : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected
              ? colors.primary.withValues(alpha: .4)
              : theme.dividerColor,
        ),
      ),
      clipBehavior: Clip.antiAlias,
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
                      padding: const EdgeInsets.fromLTRB(13, 12, 10, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(icon, size: 19, color: colors.onSurfaceVariant),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(label, style: theme.textTheme.labelLarge),
                                if (chapter.isNotEmpty)
                                  Text(
                                    chapter,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                if (body.isNotEmpty) ...[
                                  const SizedBox(height: 6),
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
                IconButton(
                  tooltip: tr(context, 'Delete'),
                  onPressed: delete,
                  icon: const Icon(Icons.delete_outline, size: 19),
                ),
            ],
          ),
          if (noteLabel != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 10, 6),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  alignment: AlignmentDirectional.centerStart,
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
    );
  }
}

class _SelectionPosition extends SingleChildLayoutDelegate {
  const _SelectionPosition(this.anchor);
  final Rect anchor;
  static const gap = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.max(0, math.min(440, constraints.maxWidth - gap * 2)),
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
    final below = rect.bottom + gap, above = rect.top - childSize.height - gap;
    final y = (below + childSize.height <= size.height - gap ? below : above)
        .clamp(gap, math.max(gap, size.height - childSize.height - gap));
    return Offset(x.toDouble(), y.toDouble());
  }

  @override
  bool shouldRelayout(_SelectionPosition oldDelegate) =>
      oldDelegate.anchor != anchor;
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
