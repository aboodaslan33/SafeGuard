import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

/// 4pt spacing scale. Use these instead of literal paddings.
abstract final class SgSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x10 = 40;
  static const double x12 = 48;
  static const double x16 = 64;

  /// Horizontal gutter for every screen.
  static const double gutter = x5;

  /// Max content width so layouts stay readable on tablets / landscape.
  static const double maxContentWidth = 560;
}

abstract final class SgRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// Elevation is expressed through surface steps in dark mode (shadows are
/// invisible on near-black) and soft shadows in light mode.
abstract final class SgElevation {
  static List<BoxShadow> raised({required bool dark}) => dark
      ? const []
      : const [
          BoxShadow(
            color: Color(0x0F101820),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
          BoxShadow(
            color: Color(0x0A101820),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ];

  static List<BoxShadow> overlay({required bool dark}) => [
    BoxShadow(
      color: dark ? const Color(0x66000000) : const Color(0x1F101820),
      blurRadius: 32,
      offset: const Offset(0, 12),
    ),
  ];
}

/// Motion is deliberately restrained: short, eased, no bounce.
abstract final class SgMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
}
