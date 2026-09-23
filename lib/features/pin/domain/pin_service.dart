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
    this._monotonic = noMonotonicSource,
  }) : _repo = repository;

  final PinRepository _repo;
  final PinHasher _hasher;
  final Clock _clock;
  final MonotonicSource _monotonic;

  /// Upper bound for any lockout, so a clock moved backwards can't stretch
  /// a recorded lock beyond what [PinPolicy] ever hands out.
  static const _maxLockMs = 60 * 60 * 1000;

  Future<Result<PinCredential?>> credential() => guard(
    _repo.readCredential,
    onError: (e, s) => StorageFailure(cause: e, stackTrace: s),
  );

  /// Current lockout end, or null when PIN entry is allowed.
  Future<Result<DateTime?>> lockedUntil() => guard(() async {
    final attempts = await _repo.readAttempts();
    return _activeLock(attempts, _clock(), await _readMonotonic());
  }, onError: (e, s) => StorageFailure(cause: e, stackTrace: s));

  Future<MonotonicReading?> _readMonotonic() async {
    try {
      return await _monotonic();
    } catch (_) {
      return null;
    }
  }

  /// End of the lockout still in force, or null.
  ///
  /// * Same boot as when the lock started: the monotonic clock decides, so
  ///   changing the date/time has no effect.
  /// * After a reboot (or without a monotonic clock): the wall clock
  ///   decides, capped at the recorded length; a lock still running is
  ///   re-anchored to the new boot so the clock can't be moved afterwards.
  ///   Residual: rebooting *and* moving the clock forward can end one
  ///   lockout early — each such bypass still costs a reboot per attempt.
  Future<DateTime?> _activeLock(
    PinAttempts a,
    DateTime now,
    MonotonicReading? mono,
  ) async {
    final wallUntil = a.lockedUntil;
    if (wallUntil == null) return null;
    final lockMs = (a.lockMs ?? _maxLockMs).clamp(0, _maxLockMs);

    if (mono != null &&
        a.anchorBoot == mono.boot &&
        a.anchorElapsedMs != null &&
        mono.elapsedMs >= a.anchorElapsedMs!) {
      final remaining = lockMs - (mono.elapsedMs - a.anchorElapsedMs!);
      return remaining > 0 ? now.add(Duration(milliseconds: remaining)) : null;
    }

    final remaining = wallUntil.difference(now).inMilliseconds.clamp(0, lockMs);
    if (remaining <= 0) return null;
    final until = now.add(Duration(milliseconds: remaining));
    if (mono != null) {
      await _repo.writeAttempts(
        PinAttempts(
          failed: a.failed,
          lockedUntil: until,
          lockMs: remaining,
          anchorElapsedMs: mono.elapsedMs,
          anchorBoot: mono.boot,
        ),
      );
    }
    return until;
  }

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
      final mono = await _readMonotonic();
      final attempts = await _repo.readAttempts();
      final lockedUntil = await _activeLock(attempts, now, mono);
      if (lockedUntil != null) {
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
        PinAttempts(
          failed: failed,
          lockedUntil: until,
          lockMs: until == null ? null : lockout.inMilliseconds,
          anchorElapsedMs: until == null ? null : mono?.elapsedMs,
          anchorBoot: until == null ? null : mono?.boot,
        ),
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
