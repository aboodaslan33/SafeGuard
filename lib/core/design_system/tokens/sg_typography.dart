import 'package:flutter/material.dart';

/// Type scale tuned for Arabic.
///
/// Arabic glyphs have tall ascenders/descenders and diacritics, so line
/// heights are more generous than a Latin scale (1.45–1.65) and weights stay
/// at 600 or below for headings — heavier weights clog Naskh-style counters.
abstract final class SgTypography {
  static const String fontFamily = 'IBMPlexSansArabic';

  static TextTheme textTheme(Color primary, Color secondary) {
    return TextTheme(
      // Hero numbers / splash wordmark.
      displaySmall: TextStyle(
        fontSize: 30,
        height: 1.35,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: primary,
      ),
      // Screen titles and the main protection state headline.
      headlineSmall: TextStyle(
        fontSize: 24,
        height: 1.45,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      // Card titles, sheet titles.
      titleLarge: TextStyle(
        fontSize: 19,
        height: 1.5,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      // List item titles.
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w500,
        color: primary,
      ),
      // Section headers.
      titleSmall: TextStyle(
        fontSize: 14,
        height: 1.5,
        fontWeight: FontWeight.w600,
        color: secondary,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        height: 1.65,
        fontWeight: FontWeight.w400,
        color: primary,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.6,
        fontWeight: FontWeight.w400,
        color: secondary,
      ),
      bodySmall: TextStyle(
        fontSize: 12.5,
        height: 1.55,
        fontWeight: FontWeight.w400,
        color: secondary,
      ),
      // Buttons.
      labelLarge: TextStyle(
        fontSize: 15,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      // Status pills, chips.
      labelMedium: TextStyle(
        fontSize: 13,
        height: 1.4,
        fontWeight: FontWeight.w500,
        color: primary,
      ),
      labelSmall: TextStyle(
        fontSize: 11.5,
        height: 1.4,
        fontWeight: FontWeight.w500,
        color: secondary,
      ),
    );
  }
}
