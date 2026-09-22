import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/core/error/failures.dart';
import 'package:safeguard/core/error/result.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/pin/data/pin_data.dart';
import 'package:safeguard/features/pin/domain/pin_models.dart';
import 'package:safeguard/features/pin/domain/pin_service.dart';

void main() {
  group('PinPolicy.validate', () {
    test('accepts 4 and 6 digit PINs', () {
      expect(PinPolicy.validate('2580'), isNull);
      expect(PinPolicy.validate('019283'), isNull);
    });

    test('rejects wrong length and non-digits', () {
      for (final pin in ['', '123', '12345', '1234567', '12a4', '١٢٣٤']) {
        expect(PinPolicy.validate(pin), isA<ValidationFailure>(), reason: pin);
      }
    });

    test('rejects trivially guessable PINs', () {
      for (final pin in ['0000', '1111', '1234', '4321', '123456', '987654']) {
        expect(PinPolicy.validate(pin), isA<ValidationFailure>(), reason: pin);
      }
    });

    test('lockout escalates after the free attempts', () {
      expect(PinPolicy.lockoutFor(4), Duration.zero);
      expect(PinPolicy.lockoutFor(5), const Duration(seconds: 30));
      expect(PinPolicy.lockoutFor(6), const Duration(minutes: 1));
      expect(PinPolicy.lockoutFor(20), const Duration(hours: 1));
    });
  });

  group('PinService', () {
    late MemoryStore store;
    late DateTime now;
    late PinService service;

    setUp(() {
      store = MemoryStore();
      now = DateTime(2026, 1, 1, 12);
      service = PinService(
        repository: SecurePinRepository(store),
        hasher: const Pbkdf2PinHasher(iterations: 1000, useIsolate: false),
        clock: () => now,
      );
    });

    test('never stores the PIN in plain text', () async {
      expect(
        (await service.createPin('2580', confirmation: '2580')).isOk,
        isTrue,
      );
      final dump = store.values.values.join('|');
      expect(dump, isNot(contains('2580')));
      final credential = PinCredential.decode(store.values['pin.credential']!);
      expect(credential.salt, hasLength(16));
      expect(credential.hash, hasLength(32));
      expect(credential.length, 4);
    });

    test('same PIN produces different salts and hashes', () async {
      await service.createPin('2580', confirmation: '2580');
      final first = store.values['pin.credential'];
      await service.createPin('2580', confirmation: '2580');
      expect(store.values['pin.credential'], isNot(first));
    });

    test('rejects mismatched confirmation', () async {
      final r = await service.createPin('2580', confirmation: '2581');
      expect(r.failureOrNull, isA<ValidationFailure>());
      expect(store.values, isEmpty);
    });

    test('verify accepts the right PIN and rejects the wrong one', () async {
      await service.createPin('739154', confirmation: '739154');
      expect((await service.verify('739154')).isOk, isTrue);

      final wrong = await service.verify('739155');
      expect(wrong.failureOrNull, isA<PinMismatchFailure>());
      expect(
        (wrong.failureOrNull! as PinMismatchFailure).remainingAttempts,
        PinPolicy.freeAttempts - 1,
      );
    });

    test('locks out after repeated failures, even for the right PIN', () async {
      await service.createPin('2580', confirmation: '2580');
      Result<void> last = const Ok(null);
      for (var i = 0; i < PinPolicy.freeAttempts; i++) {
        last = await service.verify('0000');
      }
      expect(last.failureOrNull, isA<PinLockedFailure>());
      expect(
        (await service.verify('2580')).failureOrNull,
        isA<PinLockedFailure>(),
      );

      now = now.add(const Duration(seconds: 31));
      expect((await service.verify('2580')).isOk, isTrue);
      expect((await service.lockedUntil()).valueOrNull, isNull);
    });

    test('attempt counter persists across service instances', () async {
      await service.createPin('2580', confirmation: '2580');
      for (var i = 0; i < 3; i++) {
        await service.verify('0000');
      }
      final restarted = PinService(
        repository: SecurePinRepository(store),
        hasher: const Pbkdf2PinHasher(iterations: 1000, useIsolate: false),
        clock: () => now,
      );
      final r = await restarted.verify('0000');
      expect((r.failureOrNull! as PinMismatchFailure).remainingAttempts, 1);
    });

    test('changePin requires the current PIN', () async {
      await service.createPin('2580', confirmation: '2580');
      final denied = await service.changePin(
        current: '1111',
        next: '739154',
        confirmation: '739154',
      );
      expect(denied.failureOrNull, isA<PinMismatchFailure>());
      expect((await service.verify('2580')).isOk, isTrue);

      final ok = await service.changePin(
        current: '2580',
        next: '739154',
        confirmation: '739154',
      );
      expect(ok.isOk, isTrue);
      expect((await service.verify('739154')).isOk, isTrue);
      expect((await service.verify('2580')).isOk, isFalse);
    });

    test('storage errors surface as StorageFailure', () async {
      store.failWith = Exception('disk');
      final r = await service.createPin('2580', confirmation: '2580');
      expect(r.failureOrNull, isA<StorageFailure>());
    });

    test('corrupted credential is reported, not treated as no PIN', () async {
      store.values['pin.credential'] = '{broken';
      final r = await service.verify('2580');
      expect(r.failureOrNull, isA<CorruptedDataFailure>());
    });
  });
}
