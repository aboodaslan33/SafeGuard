import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../../../core/utils/clock.dart';
import 'pin_models.dart';

/// PIN use cases: create, verify (with throttling) and change.
class PinService {
  PinService({
    required PinRepository repository,
    required this._hasher,
    this._clock = systemClock,
  }) : _repo = repository;

  final PinRepository _repo;
  final PinHasher _hasher;
  final Clock _clock;

  Future<Result<PinCredential?>> credential() => guard(
    _repo.readCredential,
    onError: (e, s) => StorageFailure(cause: e, stackTrace: s),
  );

  /// Current lockout end, or null when PIN entry is allowed.
  Future<Result<DateTime?>> lockedUntil() => guard(() async {
    final attempts = await _repo.readAttempts();
    final until = attempts.lockedUntil;
    return until != null && _clock().isBefore(until) ? until : null;
  }, onError: (e, s) => StorageFailure(cause: e, stackTrace: s));

  /// Validates and stores a new PIN. Overwrites any existing PIN, so callers
  /// that replace a PIN must go through [changePin].
  Future<Result<void>> createPin(String pin, {required String confirmation}) {
    return guard(() async {
      final invalid = PinPolicy.validate(pin);
      if (invalid != null) throw invalid;
      if (pin != confirmation) {
        throw const ValidationFailure('الرمزان غير متطابقين');
      }
      final credential = await _hasher.create(pin);
      await _repo.writeCredential(credential);
      await _repo.writeAttempts(PinAttempts.none);
    }, onError: (e, s) => StorageFailure(cause: e, stackTrace: s));
  }

  /// Verifies [pin]. Failures are [PinMismatchFailure] or
  /// [PinLockedFailure]; the attempt counter survives app restarts.
  Future<Result<void>> verify(String pin) {
    return guard(() async {
      final now = _clock();
      final attempts = await _repo.readAttempts();
      final lockedUntil = attempts.lockedUntil;
      if (lockedUntil != null && now.isBefore(lockedUntil)) {
        throw PinLockedFailure(lockedUntil: lockedUntil);
      }

      final credential = await _repo.readCredential();
      if (credential == null) {
        throw const ValidationFailure('لم يتم إعداد رمز PIN بعد');
      }

      if (await _hasher.matches(pin, credential)) {
        if (attempts.failed != 0) await _repo.writeAttempts(PinAttempts.none);
        return;
      }

      final failed = attempts.failed + 1;
      final lockout = PinPolicy.lockoutFor(failed);
      final until = lockout == Duration.zero ? null : now.add(lockout);
      await _repo.writeAttempts(
        PinAttempts(failed: failed, lockedUntil: until),
      );
      if (until != null) throw PinLockedFailure(lockedUntil: until);
      throw PinMismatchFailure(
        remainingAttempts: PinPolicy.freeAttempts - failed,
      );
    }, onError: (e, s) => StorageFailure(cause: e, stackTrace: s));
  }

  /// Replaces the PIN only after the current one is verified.
  Future<Result<void>> changePin({
    required String current,
    required String next,
    required String confirmation,
  }) async {
    final verified = await verify(current);
    if (verified case Err(:final failure)) return Err(failure);
    return createPin(next, confirmation: confirmation);
  }
}
