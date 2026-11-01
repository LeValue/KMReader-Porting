import 'package:flutter/material.dart';

Color readerInk(Color page) =>
    page.computeLuminance() > .179 ? Colors.black : Colors.white;

class ReaderCapsule extends StatelessWidget {
  const ReaderCapsule({
    super.key,
    required this.child,
    this.dark = false,
    this.background,
    this.foreground,
  });
  final Widget child;
  final bool dark;
  final Color? background, foreground;
  @override
  Widget build(BuildContext context) {
    final paper =
        background ??
        (dark
            ? const Color(0xff242424)
            : Theme.of(context).colorScheme.surface);
    var ink = foreground ?? readerInk(paper);
    // Publisher themes can specify a low-contrast foreground. Controls must
    // remain readable even when an authored text palette is unsuitable.
    final a = paper.computeLuminance(), b = ink.computeLuminance();
    if ((a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05)) < 4.5) {
      ink = readerInk(paper);
    }
    final fill = Color.alphaBlend(
      (ink.computeLuminance() > .5 ? Colors.black : Colors.white).withValues(
        alpha: .1,
      ),
      paper,
    );
    final resolved = ink;
    final style = ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => resolved.withValues(
          alpha: states.contains(WidgetState.disabled) ? .45 : 1,
        ),
      ),
    );
    return Material(
      color: fill.withValues(alpha: .96),
      borderRadius: BorderRadius.circular(28),
      child: IconButtonTheme(
        data: IconButtonThemeData(style: style),
        child: TextButtonTheme(
          data: TextButtonThemeData(style: style),
          child: IconTheme(
            data: IconThemeData(size: 20, color: ink),
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: 12, color: ink),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
