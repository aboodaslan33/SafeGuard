import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

/// Build identity shown in About and Diagnostics.
abstract final class AppInfo {
  /// Keep in sync with `version:` in pubspec.yaml (checked by a test).
  static const version = '1.7.0';
  static const buildNumber = 8;

  /// Android product flavor: dev, staging or prod (null when built without
  /// flavors, e.g. tests).
  static String get flavor => appFlavor ?? 'prod';

  static String get buildMode => kReleaseMode
      ? 'release'
      : kProfileMode
      ? 'profile'
      : 'debug';

  static String get full => '$version ($buildNumber) · $flavor · $buildMode';
}
