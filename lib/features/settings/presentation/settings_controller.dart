import 'package:flutter/foundation.dart';

import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../../../core/i18n/i18n.dart';
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

  /// In memory only: set when the PIN is created on first run, so the
  /// router opens the protection setup wizard next; cleared by the wizard.
  bool _setupPending = false;
  bool get setupPending => _setupPending;
  set setupPending(bool value) {
    if (_setupPending == value) return;
    _setupPending = value;
    notifyListeners();
  }

  Future<Result<void>> completeOnboarding() =>
      _update(_settings.copyWith(onboardingCompleted: true));

  Future<Result<void>> setTheme(ThemePreference theme) =>
      _update(_settings.copyWith(theme: theme));

  Future<Result<void>> setLanguage(AppLanguage language) =>
      _update(_settings.copyWith(language: language));

  Future<Result<void>> setAppLock(bool enabled) =>
      _update(_settings.copyWith(appLockEnabled: enabled));

  /// PIN checks happen in the UI (turning the lock off needs the PIN).
  Future<Result<void>> setProtectionLock(bool locked) =>
      _update(_settings.copyWith(protectionLocked: locked));

  /// Called after all app data was wiped.
  /// The chosen language survives: the user still reads the same language
  /// on the first-run screens.
  void resetInMemory() {
    _settings = AppSettings(language: _settings.language);
    notifyListeners();
    _repository.save(_settings).ignore();
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
