import 'package:flutter/material.dart';

import '../../ui/strings.dart';

ThemeData settingsTheme(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  const secondary = Color(0xff8e8e93);
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        fontSize: 17,
        letterSpacing: 0,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 15,
        letterSpacing: 0,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontSize: 13,
        letterSpacing: 0,
        color: secondary,
      ),
    ),
    scaffoldBackgroundColor: dark ? Colors.black : const Color(0xfff2f2f7),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: dark ? Colors.black : const Color(0xfff2f2f7),
    ),
    cardTheme: CardThemeData(
      color: dark ? const Color(0xff1c1c1e) : Colors.white,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
    ),
    dividerTheme: DividerThemeData(
      color: (dark ? Colors.white : Colors.black).withValues(alpha: .09),
      thickness: .5,
      space: .5,
    ),
    listTileTheme: base.listTileTheme.copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      titleTextStyle: base.textTheme.bodyLarge?.copyWith(fontSize: 17),
      subtitleTextStyle: base.textTheme.bodySmall?.copyWith(
        fontSize: 13,
        height: 1.35,
        color: secondary,
      ),
      minVerticalPadding: 12,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const Color(0xff30c95b)
            : (dark ? const Color(0xff545458) : const Color(0xffc7c7cc)),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: dark ? Colors.white : Colors.black,
      inactiveTrackColor: dark
          ? const Color(0xff3a3a3c)
          : const Color(0xffe5e5ea),
      thumbColor: Colors.white,
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(
        enabledThumbRadius: 10,
        elevation: 2,
      ),
    ),
  );
}

class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.backgroundColor,
    this.showBackButton = true,
  });
  final String title;
  final Widget body;
  final Color? backgroundColor;
  final bool showBackButton;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) => Theme(
    data: settingsTheme(Theme.of(context)),
    child: Builder(
      builder: (context) => Scaffold(
        backgroundColor: backgroundColor,
        appBar: AppBar(
          backgroundColor:
              backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
          automaticallyImplyLeading: false,
          title: Text(
            tr(context, title),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          leading: showBackButton && Navigator.canPop(context)
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: Theme(
                    data: Theme.of(context)
                        .copyWith(platform: TargetPlatform.iOS),
                    child: BackButton(
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface
                            .withValues(alpha: .8),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                )
              : null,
          actions: actions,
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: body,
          ),
        ),
      ),
    ),
  );
}

class SettingsHeading extends StatelessWidget {
  const SettingsHeading(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
    child: Text(
      tr(context, title),
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Color(0xff8e8e93),
      ),
    ),
  );
}
