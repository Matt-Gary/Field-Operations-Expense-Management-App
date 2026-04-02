import 'package:flutter/material.dart';
import 'enterprise_colors.dart';

ThemeData enterpriseTheme() {
  final scheme = ColorScheme(
    brightness: Brightness.light,
    primary: kPrimaryDark,
    onPrimary: kOnPrimary,
    secondary: kAccent,
    onSecondary: Colors.white,
    error: kError,
    onError: kOnError,
    surface: kSurface,
    onSurface: kOnSurface,
    tertiary: kPrimary,
    onTertiary: Colors.white,
    outline: kOutline,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent, // gradient sits behind
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      centerTitle: true,
      elevation: 0,
      titleTextStyle: const TextStyle(
        fontSize: 20, fontWeight: FontWeight.w700, color: kOnPrimary,
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 16, color: kOnSurface),
      bodyMedium: TextStyle(fontSize: 14, color: kOnSurface),
      labelLarge: TextStyle(fontWeight: FontWeight.w700),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(160, 52), // bigger touch target
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.secondary,
        foregroundColor: scheme.onSecondary,
        minimumSize: const Size(160, 52),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        side: BorderSide(color: scheme.outline, width: 2),
        minimumSize: const Size(160, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSurface, // white field for contrast on gradient
      labelStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.9)),
      hintStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.7)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.outline, width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.outline, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: scheme.outline, width: 2),
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? scheme.primary : Colors.white),
      checkColor: WidgetStateProperty.all(Colors.white),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? scheme.primary : Colors.grey.shade400),
      thumbColor: WidgetStateProperty.all(Colors.white),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.primary,
      contentTextStyle: const TextStyle(color: kOnPrimary),
    ),
  );
}
