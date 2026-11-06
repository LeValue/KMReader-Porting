import 'package:flutter/material.dart';

/// Destinations share a row even on compact phones. Keep labels on one
/// baseline; the complete destination name remains available to semantics.
class ShellNavigationBar extends StatelessWidget {
  const ShellNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.labels,
    required this.icons,
    required this.onSelected,
  });
  final int selectedIndex;
  final List<String> labels;
  final List<IconData> icons;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) => NavigationBar(
    selectedIndex: selectedIndex,
    labelPadding: const EdgeInsets.symmetric(horizontal: 2),
    labelTextStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 11)),
    onDestinationSelected: onSelected,
    destinations: [
      for (var i = 0; i < labels.length; i++)
        DefaultTextStyle.merge(
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          child: NavigationDestination(icon: Icon(icons[i]), label: labels[i]),
        ),
    ],
  );
}
