import 'package:flutter/material.dart';

/// Bounded forms and dashboards retain section state and exact content height.
/// Use lazy lists for unbounded catalogs, logs and rows inside horizontal shelves.
class SectionScrollView extends StatelessWidget {
  const SectionScrollView({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
    this.controller,
    this.physics,
  });
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final ScrollController? controller;
  final ScrollPhysics? physics;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    controller: controller,
    primary: controller == null ? null : false,
    physics: physics,
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final child in children) RepaintBoundary(child: child)],
    ),
  );
}
