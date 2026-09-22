import 'package:flutter/material.dart';

/// Semantic color tokens for SafeGuard.
///
/// Screens never reference raw hex values; they read these tokens through
/// `context.colors`. Protected state shares the brand accent on purpose:
/// in SafeGuard, "brand" and "you are protected" are the same signal.
@immutable
class SgColors extends ThemeExtension<SgColors> {
  const SgColors({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.onAccent,
    required this.accentMuted,
    required this.warning,
    required this.warningMuted,
    required this.danger,
    required this.dangerMuted,
    required this.info,
    required this.infoMuted,
    required this.scrim,
  });

  /// App canvas.
  final Color background;

  /// Default card surface.
  final Color surface;

  /// Surfaces that sit above cards (sheets, dialogs, pressed keys).
  final Color surfaceRaised;

  /// Recessed wells (inputs, keypad background, stat wells).
  final Color surfaceSunken;

  final Color border;
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// Brand + "protected" state.
  final Color accent;
  final Color onAccent;
  final Color accentMuted;

  /// Paused / needs attention. Never used for errors.
  final Color warning;
  final Color warningMuted;

  /// Errors and destructive actions only.
  final Color danger;
  final Color dangerMuted;

  /// Neutral informational notices (e.g. "not available yet").
  final Color info;
  final Color infoMuted;

  final Color scrim;

  static const dark = SgColors(
    background: Color(0xFF0D1012),
    surface: Color(0xFF151A1D),
    surfaceRaised: Color(0xFF1C2226),
    surfaceSunken: Color(0xFF0A0C0E),
    border: Color(0xFF232A2F),
    borderStrong: Color(0xFF323B41),
    textPrimary: Color(0xFFE9EDEF),
    textSecondary: Color(0xFFA0AAB0),
    textTertiary: Color(0xFF6E787E),
    accent: Color(0xFF5BB89F),
    onAccent: Color(0xFF05201A),
    accentMuted: Color(0xFF15302A),
    warning: Color(0xFFE0A955),
    warningMuted: Color(0xFF2D2517),
    danger: Color(0xFFE5736A),
    dangerMuted: Color(0xFF2F1B19),
    info: Color(0xFF8DAED6),
    infoMuted: Color(0xFF18212C),
    scrim: Color(0xB3000000),
  );

  static const light = SgColors(
    background: Color(0xFFF3F5F4),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFE9EDEC),
    border: Color(0xFFE0E5E3),
    borderStrong: Color(0xFFC9D1CE),
    textPrimary: Color(0xFF121719),
    textSecondary: Color(0xFF4F5A5F),
    textTertiary: Color(0xFF7A858A),
    accent: Color(0xFF1E7D66),
    onAccent: Color(0xFFFFFFFF),
    accentMuted: Color(0xFFE1F0EA),
    warning: Color(0xFF9A620A),
    warningMuted: Color(0xFFFAEFD9),
    danger: Color(0xFFBF3F37),
    dangerMuted: Color(0xFFFAE5E3),
    info: Color(0xFF355E8F),
    infoMuted: Color(0xFFE5EDF7),
    scrim: Color(0x80000000),
  );

  @override
  SgColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceSunken,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? onAccent,
    Color? accentMuted,
    Color? warning,
    Color? warningMuted,
    Color? danger,
    Color? dangerMuted,
    Color? info,
    Color? infoMuted,
    Color? scrim,
  }) {
    return SgColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      accentMuted: accentMuted ?? this.accentMuted,
      warning: warning ?? this.warning,
      warningMuted: warningMuted ?? this.warningMuted,
      danger: danger ?? this.danger,
      dangerMuted: dangerMuted ?? this.dangerMuted,
      info: info ?? this.info,
      infoMuted: infoMuted ?? this.infoMuted,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  SgColors lerp(ThemeExtension<SgColors>? other, double t) {
    if (other is! SgColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return SgColors(
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      surfaceSunken: l(surfaceSunken, other.surfaceSunken),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textTertiary: l(textTertiary, other.textTertiary),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentMuted: l(accentMuted, other.accentMuted),
      warning: l(warning, other.warning),
      warningMuted: l(warningMuted, other.warningMuted),
      danger: l(danger, other.danger),
      dangerMuted: l(dangerMuted, other.dangerMuted),
      info: l(info, other.info),
      infoMuted: l(infoMuted, other.infoMuted),
      scrim: l(scrim, other.scrim),
    );
  }
}
