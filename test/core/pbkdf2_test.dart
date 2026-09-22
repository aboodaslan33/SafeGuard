import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/core/security/pbkdf2.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('pbkdf2HmacSha256 (RFC 7914 §11 vectors)', () {
    test('passwd / salt / c=1', () {
      final out = pbkdf2HmacSha256(
        password: utf8.encode('passwd'),
        salt: utf8.encode('salt'),
        iterations: 1,
        keyLength: 64,
      );
      expect(
        hex(out),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
    });

    test('Password / NaCl / c=80000', () {
      final out = pbkdf2HmacSha256(
        password: utf8.encode('Password'),
        salt: utf8.encode('NaCl'),
        iterations: 80000,
        keyLength: 64,
      );
      expect(
        hex(out),
        '4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56'
        'a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d',
      );
    });

    test('rejects invalid parameters', () {
      expect(
        () => pbkdf2HmacSha256(
          password: [1],
          salt: [1],
          iterations: 0,
          keyLength: 32,
        ),
        throwsArgumentError,
      );
    });
  });

  test('constantTimeEquals', () {
    expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
  });

  test('secureRandomBytes produces distinct salts', () {
    final a = secureRandomBytes(16);
    final b = secureRandomBytes(16);
    expect(a, hasLength(16));
    expect(hex(a), isNot(hex(b)));
  });
}
