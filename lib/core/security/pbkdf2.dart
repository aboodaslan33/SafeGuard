import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PBKDF2 with HMAC-SHA256 (RFC 8018 §5.2).
///
/// Implemented on top of `package:crypto` so the app needs no native crypto
/// dependency. Verified against the RFC 7914 §11 test vector in tests.
Uint8List pbkdf2HmacSha256({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  required int keyLength,
}) {
  if (iterations < 1) throw ArgumentError.value(iterations, 'iterations');
  if (keyLength < 1) throw ArgumentError.value(keyLength, 'keyLength');

  final hmac = Hmac(sha256, password);
  const hLen = 32;
  final blocks = (keyLength + hLen - 1) ~/ hLen;
  final out = BytesBuilder(copy: false);

  for (var i = 1; i <= blocks; i++) {
    final blockIndex = Uint8List(4)
      ..buffer.asByteData().setUint32(0, i, Endian.big);
    var u = hmac.convert([...salt, ...blockIndex]).bytes;
    final t = Uint8List.fromList(u);
    for (var j = 1; j < iterations; j++) {
      u = hmac.convert(u).bytes;
      for (var k = 0; k < hLen; k++) {
        t[k] ^= u[k];
      }
    }
    out.add(t);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, keyLength);
}

/// Compares two byte lists in time independent of where they differ.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Cryptographically secure random bytes (salt generation).
Uint8List secureRandomBytes(int length, [Random? random]) {
  final rng = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rng.nextInt(256)),
  );
}
