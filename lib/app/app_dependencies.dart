import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/error/app_logger.dart';
import '../core/error/failures.dart';
import '../core/error/result.dart';
import '../core/observability/crash_reporter.dart';
import '../core/observability/telemetry.dart';
import '../core/platform/protection_channel.dart';
import '../core/storage/stores.dart';
import '../features/pin/data/pin_data.dart';
import '../features/pin/domain/pin_models.dart';
import '../features/pin/domain/pin_service.dart';
import '../features/pin/presentation/security_controller.dart';
import '../features/protection/data/local_protection_repository.dart';
import '../features/protection/data/native_protection_engine.dart';
import '../features/protection/domain/protection.dart';
import '../features/protection/presentation/protection_controller.dart';
import '../features/settings/data/local_settings_repository.dart';
import '../features/settings/presentation/settings_controller.dart';
import 'app_info.dart';

/// Android's time-since-boot and boot id, for the PIN lockout.
MonotonicSource platformMonotonicSource([ProtectionChannel? channel]) {
  final c = channel ?? ProtectionChannel();
  return () async {
    final m = await c.monotonicTime();
    final elapsed = m['elapsedMs'];
    final boot = m['boot'];
    if (elapsed is! int || boot is! int || boot < 0) return null;
    return MonotonicReading(elapsedMs: elapsed, boot: boot);
  };
}

enum BootStatus { loading, ready, failed }

/// Composition root. The only place where concrete implementations are
/// chosen; everything else depends on interfaces.
class AppDependencies extends ChangeNotifier {
  AppDependencies({
    required KeyValueStore preferences,
    required SecureStore secureStore,
    required PinHasher hasher,
    ProtectionEngine engine = const UnavailableProtectionEngine(),
    MonotonicSource monotonic = noMonotonicSource,
  }) : _preferences = preferences,
       _secureStore = secureStore {
    settings = SettingsController(LocalSettingsRepository(preferences));
    protection = ProtectionController(
      repository: LocalProtectionRepository(preferences),
      engine: engine,
    );
    crashes = LocalCrashReporter(preferences, appVersion: AppInfo.version);
    telemetry = LocalTelemetry(preferences);
    security = SecurityController(
      PinService(
        repository: SecurePinRepository(secureStore),
        hasher: hasher,
        monotonic: monotonic,
      ),
    );
  }

  factory AppDependencies.production() {
    // The VPN / DNS engine exists only in the Android host.
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return AppDependencies(
      preferences: SharedPrefsStore(),
      secureStore: KeystoreSecureStore(),
      hasher: const Pbkdf2PinHasher(),
      engine: android
          ? NativeProtectionEngine()
          : const UnavailableProtectionEngine(),
      monotonic: android ? platformMonotonicSource() : noMonotonicSource,
    );
  }

  final KeyValueStore _preferences;
  final SecureStore _secureStore;

  late final SettingsController settings;
  late final ProtectionController protection;
  late final SecurityController security;

  /// Local-only crash records (view / copy / delete; can be turned off).
  late final LocalCrashReporter crashes;

  /// Opt-in, aggregated, local-only counts (off by default).
  late final LocalTelemetry telemetry;

  /// Routes app-wide errors to the crash reporter and telemetry.
  void observeErrors() {
    AppLogger.onError = (tag, error, stack) {
      final event = switch (tag) {
        'flutter' || 'uncaught' => TelemetryEvent.crash,
        'health' || 'recover' => TelemetryEvent.healthCheckFailure,
        'ai' => TelemetryEvent.aiUnavailable,
        'guard' || 'protection' => TelemetryEvent.storageFailure,
        _ => TelemetryEvent.engineFailure,
      };
      unawaited(telemetry.count(event));
      if (event == TelemetryEvent.crash) {
        unawaited(crashes.record(error, stack));
      }
    };
  }

  BootStatus _status = BootStatus.loading;
  BootStatus get status => _status;

  AppFailure? _failure;
  AppFailure? get failure => _failure;

  Future<void> initialize() async {
    _status = BootStatus.loading;
    notifyListeners();
    await crashes.load();
    await telemetry.load();
    final results = await Future.wait([
      settings.load(),
      protection.load(),
      security.load(),
    ]);
    unawaited(_loadDeviceInfo());
    _failure = results.map((r) => r.failureOrNull).nonNulls.firstOrNull;
    _status = _failure == null ? BootStatus.ready : BootStatus.failed;
    notifyListeners();
  }

  /// Android version and model for crash records (from native diagnostics).
  Future<void> _loadDeviceInfo() async {
    if (!protection.engine.isSupported) return;
    try {
      final d = await protection.engine.diagnostics();
      crashes
        ..androidVersion = d['androidRelease'] is String
            ? d['androidRelease']! as String
            : null
        ..deviceModel = d['model'] is String ? d['model']! as String : null;
    } catch (_) {}
  }

  /// Erases every SafeGuard value on the device and returns to first run:
  /// stops the VPN and deletes native rules, logs and config too.
  Future<Result<void>> eraseAllData() async {
    final result = await guard(() async {
      if (protection.engine.isSupported) await protection.engine.eraseAll();
      await _secureStore.clear();
      await _preferences.clear();
    }, onError: (e, s) => StorageFailure(cause: e, stackTrace: s));
    if (result.isOk) {
      settings.resetInMemory();
      protection.resetInMemory();
      security.resetInMemory();
    }
    return result;
  }
}

/// Makes [AppDependencies] reachable from any widget.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.dependencies, required super.child});

  final AppDependencies dependencies;

  static AppDependencies of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree');
    return scope!.dependencies;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      dependencies != oldWidget.dependencies;
}
