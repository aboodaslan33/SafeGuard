import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/error/failures.dart';
import '../core/error/result.dart';
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

enum BootStatus { loading, ready, failed }

/// Composition root. The only place where concrete implementations are
/// chosen; everything else depends on interfaces.
class AppDependencies extends ChangeNotifier {
  AppDependencies({
    required KeyValueStore preferences,
    required SecureStore secureStore,
    required PinHasher hasher,
    ProtectionEngine engine = const UnavailableProtectionEngine(),
  }) : _preferences = preferences,
       _secureStore = secureStore {
    settings = SettingsController(LocalSettingsRepository(preferences));
    protection = ProtectionController(
      repository: LocalProtectionRepository(preferences),
      engine: engine,
    );
    security = SecurityController(
      PinService(repository: SecurePinRepository(secureStore), hasher: hasher),
    );
  }

  factory AppDependencies.production() => AppDependencies(
    preferences: SharedPrefsStore(),
    secureStore: KeystoreSecureStore(),
    hasher: const Pbkdf2PinHasher(),
    // The VPN / DNS engine exists only in the Android host.
    engine: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? NativeProtectionEngine()
        : const UnavailableProtectionEngine(),
  );

  final KeyValueStore _preferences;
  final SecureStore _secureStore;

  late final SettingsController settings;
  late final ProtectionController protection;
  late final SecurityController security;

  BootStatus _status = BootStatus.loading;
  BootStatus get status => _status;

  AppFailure? _failure;
  AppFailure? get failure => _failure;

  Future<void> initialize() async {
    _status = BootStatus.loading;
    notifyListeners();
    final results = await Future.wait([
      settings.load(),
      protection.load(),
      security.load(),
    ]);
    _failure = results.map((r) => r.failureOrNull).nonNulls.firstOrNull;
    _status = _failure == null ? BootStatus.ready : BootStatus.failed;
    notifyListeners();
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
