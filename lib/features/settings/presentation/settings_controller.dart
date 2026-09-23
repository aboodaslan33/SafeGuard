import 'package:flutter/foundation.dart';

import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../domain/app_settings.dart';

class SettingsController extends ChangeNotifier {
  SettingsController(this._repository);

  final SettingsRepository _repository;

  AppSettings _settings = const AppSettings();
  AppSettings get settings => _settings;

  Future<Result<void>> load() async {
    final result = await guard(
      _repository.load,
      onError: (e, s) => StorageFailure(cause: e, stackTrace: s),
    );
    if (result case Ok(:final value)) {
      _settings = value;
      notifyListeners();
    }
    return result;
  }

  Future<Result<void>> completeOnboarding() =>
      _update(_settings.copyWith(onboardingCompleted: true));

  Future<Result<void>> setTheme(ThemePreference theme) =>
      _update(_settings.copyWith(theme: theme));

  Future<Result<void>> setAppLock(bool enabled) =>
      _update(_settings.copyWith(appLockEnabled: enabled));

  /// PIN checks happen in the UI (turning the lock off needs the PIN).
  Future<Result<void>> setProtectionLock(bool locked) =>
      _update(_settings.copyWith(protectionLocked: locked));

  /// Called after all app data was wiped.
  void resetInMemory() {
    _settings = const AppSettings();
    notifyListeners();
  }

  /// Optimistic update: UI reflects the change immediately and rolls back
  /// if persisting fails.
  Future<Result<void>> _update(AppSettings next) async {
    final previous = _settings;
    _settings = next;
    notifyListeners();
    final result = await guard(
      () => _repository.save(next),
      onError: (e, s) => StorageFailure(cause: e, stackTrace: s),
    );
    if (!result.isOk) {
      _settings = previous;
      notifyListeners();
    }
    return result;
  }
}
