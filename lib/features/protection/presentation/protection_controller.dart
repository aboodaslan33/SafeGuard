import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/error/app_logger.dart';
import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../../../core/utils/clock.dart';
import '../domain/protection.dart';

/// What the dashboard should communicate, derived from intent + engine.
enum ProtectionHealth {
  /// VPN running, DNS filter active, rules loaded.
  active,

  /// Starting or stopping.
  transitioning,

  /// The user wants protection but it isn't running (revoked, error,
  /// permission missing, another VPN…). Needs attention.
  inactive,

  /// The user turned protection off.
  paused,

  /// No native engine on this platform.
  unsupported,
}

/// Holds the protection policy, mirrors it to the native engine, and keeps
/// the live engine status.
///
/// PIN confirmation for *loosening* protection is enforced by the UI layer
/// before calling in (see `ProtectionActions`); tightening never needs it.
class ProtectionController extends ChangeNotifier {
  ProtectionController({
    required this._repository,
    required this._engine,
    this._clock = systemClock,
  });

  final ProtectionRepository _repository;
  final ProtectionEngine _engine;
  final Clock _clock;
  StreamSubscription<EngineSnapshot>? _subscription;

  ProtectionEngine get engine => _engine;

  ProtectionState _state = ProtectionState.initial();
  ProtectionState get state => _state;

  EngineSnapshot _snapshot = EngineSnapshot.initial;
  EngineSnapshot get snapshot => _snapshot;

  ProtectionStats _stats = ProtectionStats.unavailable;
  ProtectionStats get stats => _stats;

  ProtectionHealth get health {
    if (!_engine.isSupported) return ProtectionHealth.unsupported;
    if (!_state.enabled) return ProtectionHealth.paused;
    if (_snapshot.isActive) return ProtectionHealth.active;
    if (_snapshot.isTransitioning) return ProtectionHealth.transitioning;
    return ProtectionHealth.inactive;
  }

  Future<Result<void>> load() async {
    final result = await guard(() async {
      _state = await _repository.load();
    }, onError: (e, s) => StorageFailure(cause: e, stackTrace: s));
    if (_engine.isSupported) {
      _subscription ??= _engine.watch().listen(
        _onSnapshot,
        onError: (Object e, StackTrace s) => AppLogger.error('engine', e, s),
      );
      await _syncEngine(resume: true);
    } else {
      _snapshot = EngineSnapshot.unsupported;
    }
    notifyListeners();
    return result;
  }

  /// Turns protection on or off. Turning on assumes VPN consent was already
  /// obtained by the UI (see `ProtectionActions.setEnabled`).
  Future<Result<void>> setEnabled(bool enabled) async {
    if (enabled != _state.enabled) {
      final saved = await _commit(
        _state.copyWith(enabled: enabled, updatedAt: _clock()),
      );
      if (!saved.isOk) return saved;
    }
    return enabled ? startEngine() : _engineCall(_engine.stop);
  }

  /// Starts the VPN for the current policy (e.g. "restart" after revoke).
  Future<Result<void>> startEngine() => _engineCall(() async {
    await _engine.apply(_state);
    await _engine.start();
  });

  Future<Result<void>> setCategory(ProtectionCategory category, bool active) {
    if (_state.isActive(category) == active) {
      return Future.value(const Ok(null));
    }
    return _commit(_state.withCategory(category, active, _clock()));
  }

  Future<void> refreshStats() async {
    if (!_engine.isSupported) return;
    try {
      _stats = await _engine.statistics();
      notifyListeners();
    } catch (e, s) {
      AppLogger.error('stats', e, s);
    }
  }

  Future<void> refreshStatus() async {
    if (!_engine.isSupported) return;
    try {
      _onSnapshot(await _engine.status());
    } catch (e, s) {
      AppLogger.error('status', e, s);
    }
  }

  void resetInMemory() {
    _state = ProtectionState.initial();
    _stats = ProtectionStats.unavailable;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onSnapshot(EngineSnapshot next) {
    final wasActive = _snapshot.isActive;
    _snapshot = next;
    notifyListeners();
    if (next.isActive && !wasActive) unawaited(refreshStats());
  }

  /// Pushes the policy to native and, when [resume] is set, restarts a VPN
  /// that should be running but isn't — only if consent exists and no other
  /// VPN is active (starting ours would silently disconnect it).
  Future<void> _syncEngine({bool resume = false}) async {
    try {
      await _engine.apply(_state);
      _snapshot = await _engine.status();
      final shouldResume =
          resume &&
          _state.enabled &&
          _snapshot.vpnState == VpnState.stopped &&
          !_snapshot.otherVpnActive &&
          await _engine.hasVpnPermission();
      if (shouldResume) await _engine.start();
      await refreshStats();
    } catch (e, s) {
      AppLogger.error('engine', e, s);
    }
  }

  Future<Result<void>> _engineCall(Future<void> Function() call) async {
    if (!_engine.isSupported) return const Ok(null);
    final result = await guard(call);
    unawaited(refreshStatus());
    return result;
  }

  Future<Result<void>> _commit(ProtectionState next) async {
    final previous = _state;
    _state = next;
    notifyListeners();
    final result = await guard(
      () => _repository.save(next),
      onError: (e, s) => StorageFailure(cause: e, stackTrace: s),
    );
    if (!result.isOk) {
      _state = previous;
      notifyListeners();
      return result;
    }
    // The native mirror is best effort here; it is re-synced on every load.
    if (_engine.isSupported) {
      await guard(() => _engine.apply(next));
    }
    return result;
  }
}
