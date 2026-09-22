import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/security/pbkdf2.dart';
import '../../../core/storage/stores.dart';
import '../domain/pin_models.dart';

/// PBKDF2-HMAC-SHA256 with a per-PIN random 16-byte salt.
///
/// A 4–6 digit PIN has at most 10^6 combinations, so no hash can make an
/// offline attack on a stolen record expensive. The hash's job is to keep
/// the PIN out of storage in readable form; the actual defences are that the
/// record lives in Keystore-encrypted storage and that online guessing is
/// throttled by [PinPolicy.lockoutFor].
class Pbkdf2PinHasher implements PinHasher {
  const Pbkdf2PinHasher({
    this.iterations = defaultIterations,
    this.useIsolate = true,
  });

  static const defaultIterations = 120000;
  static const _saltLength = 16;
  static const _keyLength = 32;

  final int iterations;

  /// Off the UI thread in the app; inline in unit tests.
  final bool useIsolate;

  @override
  Future<PinCredential> create(String pin) async {
    final salt = secureRandomBytes(_saltLength);
    final hash = await _derive(pin, salt, iterations);
    return PinCredential(
      iterations: iterations,
      salt: salt,
      hash: hash,
      length: pin.length,
    );
  }

  @override
  Future<bool> matches(String pin, PinCredential credential) async {
    final hash = await _derive(pin, credential.salt, credential.iterations);
    return constantTimeEquals(hash, credential.hash);
  }

  Future<Uint8List> _derive(String pin, Uint8List salt, int iterations) {
    final args = _DeriveArgs(pin, salt, iterations);
    return useIsolate
        ? compute(_deriveSync, args)
        : Future.value(_deriveSync(args));
  }
}

class _DeriveArgs {
  const _DeriveArgs(this.pin, this.salt, this.iterations);
  final String pin;
  final Uint8List salt;
  final int iterations;
}

Uint8List _deriveSync(_DeriveArgs a) => pbkdf2HmacSha256(
  password: utf8.encode(a.pin),
  salt: a.salt,
  iterations: a.iterations,
  keyLength: Pbkdf2PinHasher._keyLength,
);

class SecurePinRepository implements PinRepository {
  const SecurePinRepository(this._store);

  final SecureStore _store;

  static const _credentialKey = 'pin.credential';
  static const _attemptsKey = 'pin.attempts';

  @override
  Future<PinCredential?> readCredential() async {
    final raw = await _store.read(_credentialKey);
    return raw == null ? null : PinCredential.decode(raw);
  }

  @override
  Future<void> writeCredential(PinCredential credential) =>
      _store.write(_credentialKey, credential.encode());

  @override
  Future<PinAttempts> readAttempts() async {
    final raw = await _store.read(_attemptsKey);
    return raw == null ? PinAttempts.none : PinAttempts.decode(raw);
  }

  @override
  Future<void> writeAttempts(PinAttempts attempts) =>
      _store.write(_attemptsKey, attempts.encode());

  @override
  Future<void> clear() async {
    await _store.delete(_credentialKey);
    await _store.delete(_attemptsKey);
  }
}
