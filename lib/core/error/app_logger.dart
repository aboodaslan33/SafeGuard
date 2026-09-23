import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Local-only logger. SafeGuard ships no analytics or crash-reporting SDK;
/// logs go to the platform log in debug builds and are dropped in release,
/// so nothing about the user's browsing or settings ever leaves the device.
abstract final class AppLogger {
  static void info(String tag, String message) {
    if (kReleaseMode) return;
    developer.log(message, name: 'SafeGuard/$tag');
  }

  /// Observers (crash reporter / telemetry) — also in release builds.
  /// They receive the tag (a code constant) and the error object and must
  /// sanitise it themselves.
  static void Function(String tag, Object error, StackTrace? stack)? onError;

  static void error(String tag, Object error, [StackTrace? stack]) {
    try {
      onError?.call(tag, error, stack);
    } catch (_) {
      // An observer must never break the caller.
    }
    if (kReleaseMode) return;
    developer.log(
      error.toString(),
      name: 'SafeGuard/$tag',
      error: error,
      stackTrace: stack,
      level: 1000,
    );
  }
}
