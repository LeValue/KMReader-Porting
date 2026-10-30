import 'package:flutter/material.dart';

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final foreground = dark ? const Color(0xfff2f2f7) : const Color(0xff1c1c1e);
  final background = dark ? const Color(0xff1c1c1e) : const Color(0xfff2f2f7);
  final surface = dark ? const Color(0xff2c2c2e) : Colors.white;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: foreground,
        brightness: brightness,
      ).copyWith(
        primary: foreground,
        onPrimary: dark ? Colors.black : Colors.white,
        primaryContainer: foreground.withValues(alpha: .1),
        onPrimaryContainer: foreground,
        secondaryContainer: foreground.withValues(alpha: .1),
        onSecondaryContainer: foreground,
        tertiary: foreground,
        tertiaryContainer: foreground.withValues(alpha: .1),
        onTertiaryContainer: foreground,
        surfaceTint: Colors.transparent,
        surfaceContainerHighest: dark
            ? const Color(0xff3a3a3c)
            : const Color(0xffe5e5ea),
        surface: surface,
        onSurface: foreground,
        secondary: dark ? const Color(0xff3d9b53) : const Color(0xff1b7a2e),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    fontFamily: 'Segoe UI',
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: foreground,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    dividerColor: foreground.withValues(alpha: .12),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: TextStyle(fontSize: 16, color: foreground),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: foreground,
      linearTrackColor: foreground.withValues(alpha: .12),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 48),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: foreground.withValues(alpha: .10),
      height: 70,
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w700,
        letterSpacing: -.7,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: -.5,
      ),
      titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
    ),
  );
}
