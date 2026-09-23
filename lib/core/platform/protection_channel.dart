import 'package:flutter/services.dart';

import '../error/failures.dart';

/// Raw, typed access to the native protection channel (see
/// `ProtectionChannel.kt` for the other side). This class only moves data;
/// mapping to domain models happens in `NativeProtectionEngine`.
class ProtectionChannel {
  ProtectionChannel({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel(methodChannelName),
      _events = events ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'com.safeguard.app/protection';
  static const eventChannelName = 'com.safeguard.app/protection/status';

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<Map<Object?, Object?>> statusStream() => _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .cast<Map<Object?, Object?>>();

  Future<bool> hasVpnPermission() async =>
      await _call<bool>('hasVpnPermission') ?? false;

  Future<bool> requestVpnPermission() async =>
      await _call<bool>('requestVpnPermission') ?? false;

  Future<Map<Object?, Object?>> startProtection() => _map('startProtection');
  Future<Map<Object?, Object?>> stopProtection() => _map('stopProtection');
  Future<Map<Object?, Object?>> getProtectionStatus() =>
      _map('getProtectionStatus');

  Future<Map<Object?, Object?>> setConfiguration({
    required bool enabled,
    required List<String> categories,
    String? mode,
  }) => _map('setConfiguration', {
    'enabled': enabled,
    'categories': categories,
    'mode': ?mode,
  });

  Future<Map<Object?, Object?>> updateCategory(String category, bool enabled) =>
      _map('updateCategory', {'category': category, 'enabled': enabled});

  Future<Map<Object?, Object?>> addBlockedDomain(
    String domain,
    String category,
  ) => _map('addBlockedDomain', {'domain': domain, 'category': category});

  Future<Map<Object?, Object?>> addAllowedDomain(
    String domain, {
    bool includeSubdomains = false,
  }) => _map('addAllowedDomain', {
    'domain': domain,
    'includeSubdomains': includeSubdomains,
  });

  Future<bool> removeBlockedDomain(String domain) async =>
      await _call<bool>('removeBlockedDomain', {'domain': domain}) ?? false;

  Future<bool> removeAllowedDomain(String domain) async =>
      await _call<bool>('removeAllowedDomain', {'domain': domain}) ?? false;

  Future<List<Map<Object?, Object?>>> getRules({
    String? action,
    String? source,
  }) => _list('getRules', {'action': ?action, 'source': ?source});

  Future<List<Map<Object?, Object?>>> searchRules(String query) =>
      _list('searchRules', {'query': query});

  Future<Map<Object?, Object?>> checkDomain(String domain) =>
      _map('checkDomain', {'domain': domain});

  Future<List<Map<Object?, Object?>>> getBlockedLogs({int limit = 200}) =>
      _list('getBlockedLogs', {'limit': limit});

  Future<void> clearLogs() => _call<bool>('clearLogs');

  Future<void> setUiLanguage(String language) =>
      _call<bool>('setUiLanguage', {'language': language});

  Future<String?> getLogRetention() => _call<String>('getLogRetention');

  Future<String?> setLogRetention(String id) =>
      _call<String>('setLogRetention', {'value': id});
  Future<Map<Object?, Object?>> getStatistics() => _map('getStatistics');
  Future<void> openVpnSettings() => _call<bool>('openVpnSettings');
  Future<void> eraseAll() => _call<bool>('eraseAll');

  // ---- Phase 3 ----
  Future<Map<Object?, Object?>> getSearchSettings() =>
      _map('getSearchSettings');

  Future<Map<Object?, Object?>> setSearchSettings(Map<String, Object> s) =>
      _map('setSearchSettings', s);

  Future<Map<Object?, Object?>> submitSearch(String query, String engine) =>
      _map('submitSearch', {'query': query, 'engine': engine});

  Future<List<Map<Object?, Object?>>> getProtectedApps() =>
      _list('getProtectedApps');

  Future<List<Map<Object?, Object?>>> getLaunchableApps() =>
      _list('getLaunchableApps');

  Future<Map<Object?, Object?>> addProtectedApp(String packageName) =>
      _map('addProtectedApp', {'packageName': packageName});

  Future<bool> removeProtectedApp(String packageName) async =>
      await _call<bool>('removeProtectedApp', {'packageName': packageName}) ??
      false;

  Future<Map<Object?, Object?>> getAccessibilityStatus() =>
      _map('getAccessibilityStatus');

  Future<Map<Object?, Object?>> setAccessibilityDisclosure(bool accepted) =>
      _map('setAccessibilityDisclosure', {'accepted': accepted});

  Future<void> openAccessibilitySettings() =>
      _call<bool>('openAccessibilitySettings');

  Future<void> openBatterySettings() => _call<bool>('openBatterySettings');

  Future<void> openPrivateDnsSettings() =>
      _call<bool>('openPrivateDnsSettings');

  Future<Map<Object?, Object?>> getShieldState() => _map('getShieldState');

  Future<Map<Object?, Object?>> setShieldEnabled(bool enabled) =>
      _map('setShieldEnabled', {'enabled': enabled});

  Future<Map<Object?, Object?>> setShieldAppEnabled(String app, bool enabled) =>
      _map('setShieldAppEnabled', {'app': app, 'enabled': enabled});

  Future<Map<Object?, Object?>> setShieldDisclosure(bool accepted) =>
      _map('setShieldDisclosure', {'accepted': accepted});

  Future<Map<Object?, Object?>> getAlertsState() => _map('getAlertsState');

  Future<Map<Object?, Object?>> setAlertsEnabled(bool enabled) =>
      _map('setAlertsEnabled', {'enabled': enabled});

  Future<bool> requestNotificationPermission() async =>
      await _call<bool>('requestNotificationPermission') ?? false;

  Future<void> setDecisionTraceEnabled(bool enabled) =>
      _call<bool>('setDecisionTraceEnabled', {'enabled': enabled});

  Future<Map<Object?, Object?>> getDecisionTrace() => _map('getDecisionTrace');

  /// States, counts and versions only (see ProtectionManager.diagnostics).
  Future<Map<Object?, Object?>> getDiagnostics() => _map('getDiagnostics');

  // ---- Phase 4 ----
  Future<Map<Object?, Object?>> getAiSettings() => _map('getAiSettings');

  Future<Map<Object?, Object?>> setAiSettings(Map<String, Object> s) =>
      _map('setAiSettings', s);

  Future<Map<Object?, Object?>> getAiStatistics() => _map('getAiStatistics');

  Future<void> reportFalsePositive({
    required String source,
    required String category,
    required double confidence,
  }) => _call<bool>('reportFalsePositive', {
    'source': source,
    'category': category,
    'confidence': confidence,
  });

  Future<Map<Object?, Object?>> checkImage() => _map('checkImage');

  // ---- Phase 5 ----
  Future<Map<Object?, Object?>> getHealth() => _map('getHealth');

  Future<void> acknowledgeIncidents(int upTo) =>
      _call<bool>('acknowledgeIncidents', {'upTo': upTo});

  Future<bool> tryRecover() async => await _call<bool>('tryRecover') ?? false;

  Future<Map<Object?, Object?>> startPause(int minutes) =>
      _map('startPause', {'minutes': minutes});

  Future<Map<Object?, Object?>> endPause() => _map('endPause');
  Future<Map<Object?, Object?>> enterSafeMode() => _map('enterSafeMode');
  Future<Map<Object?, Object?>> resetProtection() => _map('resetProtection');

  Future<Map<Object?, Object?>> getDetailedStatistics() =>
      _map('getDetailedStatistics');

  Future<List<Map<Object?, Object?>>> getKeywords() => _list('getKeywords');

  Future<Map<Object?, Object?>> addKeyword(String keyword, String category) =>
      _map('addKeyword', {'keyword': keyword, 'category': category});

  Future<bool> removeKeyword(int id) async =>
      await _call<bool>('removeKeyword', {'id': id}) ?? false;

  Future<Map<Object?, Object?>> saveExport(String json, {String? fileName}) =>
      _map('saveExport', {'json': json, 'fileName': ?fileName});

  /// `{elapsedMs, boot}`: time since boot and a boot id (PIN lockout).
  Future<Map<Object?, Object?>> monotonicTime() => _map('monotonicTime');

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw EngineFailure(e.code, cause: e);
    } on MissingPluginException catch (e) {
      throw EngineFailure('UNSUPPORTED', cause: e);
    }
  }

  Future<Map<Object?, Object?>> _map(String method, [Object? args]) async =>
      await _call<Map<Object?, Object?>>(method, args) ?? const {};

  Future<List<Map<Object?, Object?>>> _list(
    String method, [
    Object? args,
  ]) async {
    final raw = await _call<List<Object?>>(method, args) ?? const [];
    return raw.whereType<Map<Object?, Object?>>().toList();
  }
}
