import 'package:flutter/foundation.dart';

import '../../../core/error/result.dart';
import '../domain/pin_models.dart';
import '../domain/pin_service.dart';

/// Session-level security state: is a PIN configured, and is the app
/// currently unlocked. Unlock state lives in memory only.
class SecurityController extends ChangeNotifier {
  SecurityController(this._service);

  final PinService _service;

  bool _pinSet = false;
  bool get pinSet => _pinSet;

  int _pinLength = PinPolicy.defaultLength;
  int get pinLength => _pinLength;

  bool _unlocked = false;
  bool get unlocked => _unlocked;

  DateTime? _lockedUntil;
  DateTime? get lockedUntil => _lockedUntil;

  Future<Result<void>> load() async {
    final credential = await _service.credential();
    switch (credential) {
      case Ok(:final value):
        _pinSet = value != null;
        _pinLength = value?.length ?? PinPolicy.defaultLength;
      case Err(:final failure):
        return Err(failure);
    }
    _lockedUntil = (await _service.lockedUntil()).valueOrNull;
    notifyListeners();
    return const Ok(null);
  }

  /// Verifies [pin] and unlocks the session on success.
  Future<Result<void>> verify(String pin) async {
    final result = await _service.verify(pin);
    _lockedUntil = (await _service.lockedUntil()).valueOrNull;
    if (result.isOk) _unlocked = true;
    notifyListeners();
    return result;
  }

  Future<Result<void>> createPin(String pin, String confirmation) async {
    final result = await _service.createPin(pin, confirmation: confirmation);
    if (result.isOk) {
      _pinSet = true;
      _pinLength = pin.length;
      _unlocked = true;
      notifyListeners();
    }
    return result;
  }

  Future<Result<void>> changePin({
    required String current,
    required String next,
    required String confirmation,
  }) async {
    final result = await _service.changePin(
      current: current,
      next: next,
      confirmation: confirmation,
    );
    if (result.isOk) _pinLength = next.length;
    _lockedUntil = (await _service.lockedUntil()).valueOrNull;
    notifyListeners();
    return result;
  }

  void lock() {
    if (!_unlocked) return;
    _unlocked = false;
    notifyListeners();
  }

  void resetInMemory() {
    _pinSet = false;
    _unlocked = false;
    _lockedUntil = null;
    _pinLength = PinPolicy.defaultLength;
    notifyListeners();
  }
}
