import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../error/app_logger.dart';

/// Platform channel to the Android host (see `MainActivity.kt`).
///
/// Phase 1 uses it for one thing: marking the window as secure
/// (FLAG_SECURE) while a PIN is on screen, so the PIN never appears in
/// screenshots, screen recordings, or the recent-apps thumbnail.
abstract final class SecureScreen {
  static const _channel = MethodChannel('com.safeguard.app/device');

  static int _holders = 0;

  /// Reference-counted so overlapping PIN screens (e.g. during a step
  /// transition) don't clear the flag while one is still visible.
  static void acquire() {
    if (_holders++ == 0) unawaited(_set(true));
  }

  static void release() {
    if (_holders == 0) return;
    if (--_holders == 0) unawaited(_set(false));
  }

  static Future<void> _set(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('setSecureScreen', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Host without the channel (tests, other embedders): nothing to do.
    } on PlatformException catch (e, s) {
      AppLogger.error('secure_screen', e, s);
    }
  }
}
