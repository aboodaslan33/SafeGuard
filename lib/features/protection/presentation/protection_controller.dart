import 'package:flutter/foundation.dart';

import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../../../core/utils/clock.dart';
import '../domain/protection.dart';

/// Holds the protection policy and pushes every change to the engine.
///
/// PIN confirmation for *disabling* is enforced by the UI layer before
/// calling into this controller (see `requirePin`); enabling never needs it.
class ProtectionController extends ChangeNotifier {
  ProtectionController({
    required this._repository,
    required this._engine,
    this._clock = systemClock,
  });

  final ProtectionRepository _repository;
  final ProtectionEngine _engine;
  final Clock _clock;

  ProtectionState _state = ProtectionState.initial();
  ProtectionState get state => _state;

  EngineStatus _engineStatus = EngineStatus.notInstalled;
  EngineStatus get engineStatus => _engineStatus;

  ProtectionStats get stats => ProtectionStats.unavailable;

  Future<Result<void>> load() async {
    final result = await guard(() async {
      _state = await _repository.load();
      _engineStatus = await _engine.status();
    }, onError: (e, s) => StorageFailure(cause: e, stackTrace: s));
    notifyListeners();
    return result;
  }

  Future<Result<void>> setEnabled(bool enabled) {
    if (enabled == _state.enabled) return Future.value(const Ok(null));
    return _commit(_state.copyWith(enabled: enabled, updatedAt: _clock()));
  }

  Future<Result<void>> setCategory(ProtectionCategory category, bool active) {
    if (_state.isActive(category) == active) {
      return Future.value(const Ok(null));
    }
    return _commit(_state.withCategory(category, active, _clock()));
  }

  void resetInMemory() {
    _state = ProtectionState.initial();
    notifyListeners();
  }

  Future<Result<void>> _commit(ProtectionState next) async {
    final previous = _state;
    _state = next;
    notifyListeners();
    final result = await guard(() async {
      await _repository.save(next);
      await _engine.apply(next);
    }, onError: (e, s) => StorageFailure(cause: e, stackTrace: s));
    if (!result.isOk) {
      _state = previous;
      notifyListeners();
    }
    return result;
  }
}
