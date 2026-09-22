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
  }) =>
      _map('setConfiguration', {'enabled': enabled, 'categories': categories});

  Future<Map<Object?, Object?>> updateCategory(String category, bool enabled) =>
      _map('updateCategory', {'category': category, 'enabled': enabled});

  Future<Map<Object?, Object?>> addBlockedDomain(
    String domain,
    String category,
  ) => _map('addBlockedDomain', {'domain': domain, 'category': category});

  Future<Map<Object?, Object?>> addAllowedDomain(String domain) =>
      _map('addAllowedDomain', {'domain': domain});

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
  Future<Map<Object?, Object?>> getStatistics() => _map('getStatistics');
  Future<void> openVpnSettings() => _call<bool>('openVpnSettings');
  Future<void> eraseAll() => _call<bool>('eraseAll');

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
