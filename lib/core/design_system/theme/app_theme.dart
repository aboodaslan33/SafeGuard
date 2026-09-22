import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/sg_colors.dart';
import '../tokens/sg_tokens.dart';
import '../tokens/sg_typography.dart';

/// Builds Material [ThemeData] from SafeGuard tokens so that stock widgets
/// (Switch, NavigationBar, dialogs, sheets, snackbars) match the design
/// system without per-screen styling.
abstract final class AppTheme {
  static ThemeData dark() => _build(SgColors.dark, Brightness.dark);
  static ThemeData light() => _build(SgColors.light, Brightness.light);

  static ThemeData _build(SgColors c, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final text = SgTypography.textTheme(c.textPrimary, c.textSecondary);

    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      primaryContainer: c.accentMuted,
      onPrimaryContainer: c.accent,
      secondary: c.accent,
      onSecondary: c.onAccent,
      error: c.danger,
      onError: isDark ? c.background : Colors.white,
      errorContainer: c.dangerMuted,
      onErrorContainer: c.danger,
      surface: c.surface,
      onSurface: c.textPrimary,
      onSurfaceVariant: c.textSecondary,
      surfaceContainerLowest: c.surfaceSunken,
      surfaceContainerLow: c.background,
      surfaceContainer: c.surface,
      surfaceContainerHigh: c.surfaceRaised,
      surfaceContainerHighest: c.surfaceRaised,
      outline: c.borderStrong,
      outlineVariant: c.border,
      scrim: c.scrim,
      shadow: Colors.black,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: SgTypography.fontFamily,
      textTheme: text,
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      splashFactory: InkSparkle.splashFactory,
      extensions: [c],
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        systemOverlayStyle: _overlay(c, isDark),
      ),
      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) {
            return s.contains(WidgetState.selected)
                ? c.textTertiary
                : c.borderStrong;
          }
          return s.contains(WidgetState.selected)
              ? Colors.white
              : c.textTertiary;
        }),
        trackColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return c.surfaceSunken;
          return s.contains(WidgetState.selected) ? c.accent : c.surfaceSunken;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected) &&
              !s.contains(WidgetState.disabled)) {
            return Colors.transparent;
          }
          return c.borderStrong;
        }),
        thumbIcon: const WidgetStatePropertyAll(null),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: c.accentMuted,
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            size: 22,
            color: s.contains(WidgetState.selected) ? c.accent : c.textTertiary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => text.labelSmall!.copyWith(
            color: s.contains(WidgetState.selected)
                ? c.textPrimary
                : c.textTertiary,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w600
                : null,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: SgRadius.xlAll),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
        barrierColor: c.scrim,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: c.scrim,
        showDragHandle: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(SgRadius.xl),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? c.surfaceRaised : c.textPrimary,
        contentTextStyle: text.bodyMedium!.copyWith(
          color: isDark ? c.textPrimary : c.background,
        ),
        shape: const RoundedRectangleBorder(borderRadius: SgRadius.mdAll),
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceSunken,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: SgSpace.x4,
          vertical: SgSpace.x3,
        ),
        border: OutlineInputBorder(
          borderRadius: SgRadius.mdAll,
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: SgRadius.mdAll,
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: SgRadius.mdAll,
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: SgRadius.mdAll,
          borderSide: BorderSide(color: c.danger),
        ),
        hintStyle: text.bodyMedium!.copyWith(color: c.textTertiary),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.surfaceSunken,
        circularTrackColor: Colors.transparent,
      ),
      iconTheme: IconThemeData(color: c.textSecondary, size: 22),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  static SystemUiOverlayStyle _overlay(SgColors c, bool isDark) {
    return (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
        .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: c.background,
          systemNavigationBarDividerColor: Colors.transparent,
        );
  }
}

/// Convenience accessors used by every widget.
extension SgThemeContext on BuildContext {
  SgColors get colors => Theme.of(this).extension<SgColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}
