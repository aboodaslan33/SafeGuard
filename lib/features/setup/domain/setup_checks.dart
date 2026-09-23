import '../../protection/domain/protection.dart';

/// Result of one setup check.
enum CheckStatus {
  /// In place.
  ok,

  /// Missing and something depends on it.
  missing,

  /// Optional, but improves reliability.
  recommended,

  /// Not needed with the current configuration.
  notNeeded,

  /// Can't be determined on this device.
  unknown,
}

/// What the user can do about a check (the UI maps it to a handler).
enum CheckAction {
  grantVpn,
  startProtection,
  openVpnSettings,
  openPrivateDnsSettings,
  openAppProtection,
  openBatterySettings,
}

enum SetupCheckId {
  vpnConsent,
  protectionRunning,
  otherVpn,
  privateDns,
  accessibility,
  notifications,
  battery,
  alwaysOn,
}

class SetupCheck {
  const SetupCheck(this.id, this.status, [this.action]);
  final SetupCheckId id;
  final CheckStatus status;
  final CheckAction? action;

  bool get needsAttention =>
      status == CheckStatus.missing || status == CheckStatus.recommended;
}

/// Inputs from the engine; all optional facts may be unknown (null).
class SetupFacts {
  const SetupFacts({
    required this.supported,
    required this.vpnPermission,
    required this.snapshot,
    required this.protectionEnabled,
    required this.accessibility,
    required this.protectedAppCount,
    this.batteryOptimizationIgnored,
  });

  final bool supported;
  final bool vpnPermission;
  final EngineSnapshot snapshot;
  final bool protectionEnabled;
  final AccessibilityStatus accessibility;
  final int protectedAppCount;
  final bool? batteryOptimizationIgnored;
}

/// Pure evaluation (unit tested). Never reports "ok" for something it
/// can't observe: Always-on VPN isn't readable by apps, so it stays a
/// recommendation; notifications aren't used at all.
List<SetupCheck> evaluateSetup(SetupFacts f) {
  if (!f.supported) {
    return const [SetupCheck(SetupCheckId.vpnConsent, CheckStatus.unknown)];
  }
  final running = f.snapshot.vpnState == VpnState.running;
  return [
    SetupCheck(
      SetupCheckId.vpnConsent,
      f.vpnPermission ? CheckStatus.ok : CheckStatus.missing,
      f.vpnPermission ? null : CheckAction.grantVpn,
    ),
    SetupCheck(
      SetupCheckId.protectionRunning,
      running ? CheckStatus.ok : CheckStatus.missing,
      running ? null : CheckAction.startProtection,
    ),
    SetupCheck(
      SetupCheckId.otherVpn,
      f.snapshot.otherVpnActive && !running
          ? CheckStatus.missing
          : CheckStatus.ok,
      f.snapshot.otherVpnActive && !running
          ? CheckAction.openVpnSettings
          : null,
    ),
    SetupCheck(
      SetupCheckId.privateDns,
      f.snapshot.privateDnsStrict ? CheckStatus.missing : CheckStatus.ok,
      f.snapshot.privateDnsStrict ? CheckAction.openPrivateDnsSettings : null,
    ),
    SetupCheck(
      SetupCheckId.accessibility,
      f.protectedAppCount == 0
          ? CheckStatus.notNeeded
          : switch (f.accessibility) {
              AccessibilityStatus.enabled => CheckStatus.ok,
              AccessibilityStatus.unsupported ||
              AccessibilityStatus.unavailable => CheckStatus.unknown,
              _ => CheckStatus.missing,
            },
      f.protectedAppCount > 0 &&
              (f.accessibility == AccessibilityStatus.disabled ||
                  f.accessibility == AccessibilityStatus.permissionDenied)
          ? CheckAction.openAppProtection
          : null,
    ),
    const SetupCheck(SetupCheckId.notifications, CheckStatus.notNeeded),
    SetupCheck(
      SetupCheckId.battery,
      switch (f.batteryOptimizationIgnored) {
        true => CheckStatus.ok,
        false => CheckStatus.recommended,
        null => CheckStatus.unknown,
      },
      f.batteryOptimizationIgnored == false
          ? CheckAction.openBatterySettings
          : null,
    ),
    const SetupCheck(
      SetupCheckId.alwaysOn,
      CheckStatus.recommended,
      CheckAction.openVpnSettings,
    ),
  ];
}
