import 'dart:convert';
import 'dart:typed_data';

import '../../../core/error/failures.dart';

/// Rules for PIN format and brute-force throttling.
abstract final class PinPolicy {
  static const allowedLengths = [4, 6];
  static const defaultLength = 6;

  /// Wrong attempts allowed before the first temporary lockout.
  static const freeAttempts = 5;

  /// Escalating lockout after [freeAttempts]. Each further failure while
  /// already past the threshold locks for longer; a success resets it.
  static Duration lockoutFor(int failedAttempts) {
    if (failedAttempts < freeAttempts) return Duration.zero;
    return switch (failedAttempts - freeAttempts) {
      0 => const Duration(seconds: 30),
      1 => const Duration(minutes: 1),
      2 => const Duration(minutes: 5),
      3 => const Duration(minutes: 15),
      _ => const Duration(hours: 1),
    };
  }

  /// Returns a [ValidationFailure] when [pin] is not acceptable.
  static ValidationFailure? validate(String pin) {
    if (!RegExp(r'^\d+$').hasMatch(pin) ||
        !allowedLengths.contains(pin.length)) {
      return const ValidationFailure('الرمز يجب أن يتكوّن من 4 أو 6 أرقام');
    }
    if (_isRepeated(pin) || _isSequential(pin)) {
      return const ValidationFailure(
        'هذا الرمز سهل التخمين. اختر أرقامًا غير متتالية أو مكررة.',
      );
    }
    return null;
  }

  static bool _isRepeated(String pin) => pin.split('').toSet().length == 1;

  static bool _isSequential(String pin) {
    final d = pin.codeUnits.map((c) => c - 48).toList();
    bool step(int delta) {
      for (var i = 1; i < d.length; i++) {
        if (d[i] - d[i - 1] != delta) return false;
      }
      return true;
    }

    return step(1) || step(-1);
  }
}

/// What is persisted for a PIN: never the PIN itself, only a salted,
/// stretched hash plus the parameters needed to verify it later.
class PinCredential {
  const PinCredential({
    required this.iterations,
    required this.salt,
    required this.hash,
    required this.length,
    this.version = 1,
  });

  static const algorithm = 'pbkdf2-hmac-sha256';

  final int version;
  final int iterations;
  final Uint8List salt;
  final Uint8List hash;

  /// Digit count, so the keypad shows the right number of dots.
  final int length;

  Map<String, Object> toJson() => {
    'v': version,
    'alg': algorithm,
    'iter': iterations,
    'salt': base64Encode(salt),
    'hash': base64Encode(hash),
    'len': length,
  };

  String encode() => jsonEncode(toJson());

  static PinCredential decode(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['alg'] != algorithm) {
        throw const FormatException('unknown algorithm');
      }
      return PinCredential(
        version: json['v'] as int,
        iterations: json['iter'] as int,
        salt: base64Decode(json['salt'] as String),
        hash: base64Decode(json['hash'] as String),
        length: json['len'] as int,
      );
    } catch (e) {
      throw CorruptedDataFailure(cause: e);
    }
  }
}

/// Persisted brute-force counter.
class PinAttempts {
  const PinAttempts({this.failed = 0, this.lockedUntil});

  static const none = PinAttempts();

  final int failed;
  final DateTime? lockedUntil;

  String encode() => jsonEncode({
    'failed': failed,
    'lockedUntil': lockedUntil?.millisecondsSinceEpoch,
  });

  static PinAttempts decode(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final until = json['lockedUntil'] as int?;
      return PinAttempts(
        failed: json['failed'] as int,
        lockedUntil: until == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(until),
      );
    } catch (_) {
      // A corrupted counter must not unlock anything: treat it as a fresh
      // lockout threshold rather than zero attempts.
      return const PinAttempts(failed: PinPolicy.freeAttempts - 1);
    }
  }
}

abstract interface class PinHasher {
  Future<PinCredential> create(String pin);
  Future<bool> matches(String pin, PinCredential credential);
}

abstract interface class PinRepository {
  Future<PinCredential?> readCredential();
  Future<void> writeCredential(PinCredential credential);
  Future<PinAttempts> readAttempts();
  Future<void> writeAttempts(PinAttempts attempts);
  Future<void> clear();
}
