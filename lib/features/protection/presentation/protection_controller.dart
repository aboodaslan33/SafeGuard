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

  /// On, but not filtering on purpose: temporary unlock or Safe Mode.
  suspended,

  /// Filtering runs, but a layer that should work doesn't (health report).
  partial,

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

  SearchSettings _search = const SearchSettings();
  SearchSettings get searchSettings => _search;

  AccessibilityStatus _accessibility = AccessibilityStatus.unsupported;
  AccessibilityStatus get accessibility => _accessibility;

  // ---- Phase 5 ----
  HealthReport _healthReport = HealthReport.unknown;

  /// Native health report (layers, mode, pause, Safe Mode, interruptions).
  HealthReport get healthReport => _healthReport;

  DateTime? _pauseEndsAt;
  Timer? _pauseTimer;

  /// Remaining temporary-unlock time, counted down locally between reports.
  Duration get pauseRemaining {
    final end = _pauseEndsAt;
    if (end == null) return Duration.zero;
    final left = end.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  bool get isPaused => pauseRemaining > Duration.zero;

  int _protectedAppCount = 0;
  int get protectedAppCount => _protectedAppCount;

  Future<void> refreshHealth() async {
    if (!_engine.isSupported) return;
    try {
      _protectedAppCount = (await _engine.protectedApps()).length;
      _applyHealth(await _engine.health());
    } catch (e, s) {
      AppLogger.error('health', e, s);
    }
  }

  /// On app resume: ask native to recover a failed VPN (its policy decides),
  /// then re-read status and health.
  Future<void> onResume() async {
    if (!_engine.isSupported) return;
    try {
      await _engine.tryRecover();
    } catch (e, s) {
      AppLogger.error('recover', e, s);
    }
    await refreshStatus();
    await refreshHealth();
  }

  Future<Result<void>> acknowledgeIncidents() async {
    final result = await guard(() => _engine.acknowledgeIncidents(_clock()));
    await refreshHealth();
    return result;
  }

  /// Temporary unlock (PIN checked by the UI). Filtering resumes by itself.
  Future<Result<void>> startPause(int minutes) =>
      _healthCall(() => _engine.startPause(minutes));

  Future<Result<void>> endPause() => _healthCall(_engine.endPause);

  Future<Result<void>> enterSafeMode() async {
    final r = await _healthCall(_engine.enterSafeMode);
    unawaited(refreshStatus());
    return r;
  }

  /// Leaves Safe Mode by starting protection again (VPN consent is
  /// checked by the UI, as for any start).
  Future<Result<void>> exitSafeMode() async {
    final r = await startEngine();
    await refreshHealth();
    return r;
  }

  /// Secure defaults for every setting; lists, keywords, apps and logs stay.
  Future<Result<void>> resetProtection() async {
    final saved = await _commit(
      ProtectionState.initial().copyWith(
        enabled: _state.enabled,
        updatedAt: _clock(),
      ),
    );
    if (!saved.isOk) return saved;
    final r = await _healthCall(_engine.resetProtection);
    await _syncEngine();
    return r;
  }

  Future<Result<void>> setMode(ProtectionMode mode) {
    if (mode == _state.mode) return Future.value(const Ok(null));
    return _commit(_state.copyWith(mode: mode, updatedAt: _clock()));
  }

  Future<Result<void>> _healthCall(Future<HealthReport> Function() call) async {
    if (!_engine.isSupported) return const Ok(null);
    final result = await guard(call);
    if (result case Ok(:final value)) _applyHealth(value);
    return result;
  }

  void _applyHealth(HealthReport report) {
    _healthReport = report;
    _pauseTimer?.cancel();
    if (report.paused) {
      _pauseEndsAt = _clock().add(report.pausedRemaining);
      // Tick once a second for the countdown; re-read health when it ends.
      _pauseTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!isPaused) {
          t.cancel();
          _pauseEndsAt = null;
          unawaited(refreshHealth());
        }
        notifyListeners();
      });
    } else {
      _pauseEndsAt = null;
    }
    notifyListeners();
  }

  AiSettings _ai = const AiSettings();
  AiSettings get aiSettings => _ai;

  AiStatistics _aiStats = const AiStatistics();
  AiStatistics get aiStatistics => _aiStats;

  /// Applies AI settings natively. PIN checks for loosening happen in the UI.
  Future<Result<void>> setAiSettings(AiSettings next) async {
    if (!_engine.isSupported) {
      _ai = next;
      notifyListeners();
      return const Ok(null);
    }
    final result = await guard(() => _engine.setAiSettings(next));
    if (result case Ok(:final value)) {
      _ai = value;
      notifyListeners();
    }
    return result;
  }

  Future<void> refreshAi() async {
    if (!_engine.isSupported) return;
    try {
      _ai = await _engine.aiSettings();
      _aiStats = await _engine.aiStatistics();
      notifyListeners();
    } catch (e, s) {
      AppLogger.error('ai', e, s);
    }
  }

  /// "Report incorrect block": category, confidence, source and time only.
  Future<Result<void>> reportFalsePositive({
    required EventSourceKind source,
    required ProtectionCategory category,
    required double confidence,
  }) async {
    final result = await guard(
      () => _engine.reportFalsePositive(
        source: source,
        category: category,
        confidence: confidence,
      ),
    );
    unawaited(refreshAi());
    return result;
  }

  /// Whether search protection is enforced (presets always enforce it).
  bool get searchProtectionEnabled =>
      _state.isActive(ProtectionCategory.unsafeSearch);

  /// The user's own search switch (the Phase 1 "فلترة البحث" preference).
  bool get _userSearchOn => _state.isChosen(ProtectionCategory.unsafeSearch);

  /// Applies SafeSearch settings. The master switch is stored as the
  /// unsafeSearch category so there is a single source of truth.
  Future<Result<void>> setSearchSettings(SearchSettings next) async {
    if (next.enabled != _userSearchOn) {
      final saved = await _commit(
        _state.withCategory(
          ProtectionCategory.unsafeSearch,
          next.enabled,
          _clock(),
        ),
      );
      if (!saved.isOk) return saved;
    }
    return _pushSearch(next);
  }

  Future<void> refreshAppProtection() async {
    if (!_engine.isSupported) return;
    try {
      _accessibility = await _engine.accessibilityStatus();
      notifyListeners();
    } catch (e, s) {
      AppLogger.error('a11y', e, s);
    }
  }

  Future<Result<void>> _pushSearch(SearchSettings next) async {
    if (!_engine.isSupported) {
      _search = next;
      notifyListeners();
      return const Ok(null);
    }
    final result = await guard(() => _engine.setSearchSettings(next));
    if (result case Ok(:final value)) {
      _search = value;
      notifyListeners();
    }
    return result;
  }

  ProtectionHealth get health {
    if (!_engine.isSupported) return ProtectionHealth.unsupported;
    if (!_state.enabled) return ProtectionHealth.paused;
    if (_healthReport.safeMode || isPaused) return ProtectionHealth.suspended;
    if (_snapshot.isActive) {
      return _healthReport.overall == OverallHealth.partiallyProtected
          ? ProtectionHealth.partial
          : ProtectionHealth.active;
    }
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
    _search = const SearchSettings();
    _ai = const AiSettings();
    _aiStats = const AiStatistics();
    _pauseTimer?.cancel();
    _pauseEndsAt = null;
    _healthReport = HealthReport.unknown;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _pauseTimer?.cancel();
    super.dispose();
  }

  void _onSnapshot(EngineSnapshot next) {
    final wasActive = _snapshot.isActive;
    final stateChanged = next.vpnState != _snapshot.vpnState;
    _snapshot = next;
    notifyListeners();
    if (next.isActive && !wasActive) unawaited(refreshStats());
    // VPN transitions change health (and may be interruptions).
    if (stateChanged) unawaited(refreshHealth());
  }

  /// Pushes the policy to native and, when [resume] is set, restarts a VPN
  /// that should be running but isn't — only if consent exists and no other
  /// VPN is active (starting ours would silently disconnect it).
  Future<void> _syncEngine({bool resume = false}) async {
    try {
      await _engine.apply(_state);
      _search = await _engine.searchSettings();
      if (_search.enabled != _userSearchOn) {
        _search = await _engine.setSearchSettings(
          _search.copyWith(enabled: _userSearchOn),
        );
      }
      _accessibility = await _engine.accessibilityStatus();
      _ai = await _engine.aiSettings();
      _aiStats = await _engine.aiStatistics();
      _snapshot = await _engine.status();
      final shouldResume =
          resume &&
          _state.enabled &&
          _snapshot.vpnState == VpnState.stopped &&
          !_snapshot.otherVpnActive &&
          await _engine.hasVpnPermission();
      if (shouldResume) await _engine.start();
      await refreshStats();
      _applyHealth(await _engine.health());
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
      final searchOn = next.isChosen(ProtectionCategory.unsafeSearch);
      if (searchOn != _search.enabled) {
        await _pushSearch(_search.copyWith(enabled: searchOn));
      }
    }
    return result;
  }
}
