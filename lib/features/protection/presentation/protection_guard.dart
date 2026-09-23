import 'package:flutter/widgets.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';

/// One place for "does this protection change need the PIN?".
///
/// - Loosening (turning something off, raising a threshold, allowing a
///   domain, removing a block…) always needs the PIN.
/// - With Protection Lock on, every change to protection settings needs it.
/// - A temporary unlock pauses *filtering* only; it does not relax these
///   rules, so an unlock window can't be used to loosen settings for good.
abstract final class ProtectionGuard {
  static bool isLocked(BuildContext context) =>
      AppScope.of(context).settings.settings.protectionLocked;

  static bool needsPin(BuildContext context, {required bool loosens}) =>
      loosens || isLocked(context);

  /// True if the change may go ahead (PIN verified when required).
  static Future<bool> authorize(
    BuildContext context, {
    required bool loosens,
    required String reason,
  }) async {
    if (!needsPin(context, loosens: loosens)) return true;
    return requirePin(context, reason: reason);
  }
}
