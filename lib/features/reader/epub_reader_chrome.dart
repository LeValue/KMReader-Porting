import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/strings.dart';

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
