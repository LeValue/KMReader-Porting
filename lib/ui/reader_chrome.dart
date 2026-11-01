import 'package:flutter/material.dart';

class ReaderCapsule extends StatelessWidget {
  const ReaderCapsule({super.key, required this.child, this.dark = false});
  final Widget child;
  final bool dark;
  @override
  Widget build(BuildContext context) => Material(
    color: dark
        ? const Color(0xcc242424)
        : Theme.of(context).colorScheme.surface.withValues(alpha: .94),
    borderRadius: BorderRadius.circular(28),
    child: IconTheme(
      data: IconThemeData(size: 20, color: dark ? Colors.white : null),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 12, color: dark ? Colors.white : null),
        child: child,
      ),
    ),
  );
}
