import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/core/error/failures.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/protection/data/local_protection_repository.dart';
import 'package:safeguard/features/protection/domain/protection.dart';
import 'package:safeguard/features/protection/presentation/protection_controller.dart';
import 'package:safeguard/features/settings/data/local_settings_repository.dart';
import 'package:safeguard/features/settings/domain/app_settings.dart';
import 'package:safeguard/features/settings/presentation/settings_controller.dart';

import '../support/fake_protection_engine.dart';

class _RecordingEngine extends FakeProtectionEngine {
  final appliedStates = <ProtectionState>[];

  @override
  Future<void> apply(ProtectionState state) async {
    appliedStates.add(state);
    await super.apply(state);
  }
}

void main() {
  group('ProtectionState', () {
    test('secure default: enabled with every category on', () {
      final s = ProtectionState.initial();
      expect(s.enabled, isTrue);
      expect(s.activeCount, ProtectionCategory.values.length);
    });

    test('JSON round trip', () {
      final s = ProtectionState.initial()
          .withCategory(ProtectionCategory.gambling, false, DateTime(2026))
          .copyWith(enabled: false);
      final back = ProtectionState.fromJson(
        jsonDecode(s.encode()) as Map<String, dynamic>,
      );
      expect(back.enabled, isFalse);
      expect(back.isActive(ProtectionCategory.gambling), isFalse);
      expect(back.isActive(ProtectionCategory.sexual), isTrue);
      expect(back.updatedAt, DateTime(2026));
    });

    test('unknown ids ignored, missing categories default to on', () {
      final s = ProtectionState.fromJson({
        'enabled': true,
        'categories': {'gambling': false, 'future_category': false},
      });
      expect(s.isActive(ProtectionCategory.gambling), isFalse);
      expect(s.isActive(ProtectionCategory.unsafeSearch), isTrue);
    });

    test('nothing is effective while disabled', () {
      final s = ProtectionState.initial().copyWith(enabled: false);
      expect(s.effectiveCategories, isEmpty);
    });

    test('unreadable stored policy fails closed', () async {
      final store = MemoryStore()..values['protection.v1'] = 'not json';
      final s = await LocalProtectionRepository(store).load();
      expect(s.enabled, isTrue);
      expect(s.activeCount, ProtectionCategory.values.length);
    });
  });

  group('ProtectionController', () {
    late MemoryStore store;
    late _RecordingEngine engine;
    late ProtectionController controller;

    setUp(() async {
      store = MemoryStore();
      engine = _RecordingEngine();
      controller = ProtectionController(
        repository: LocalProtectionRepository(store),
        engine: engine,
        clock: () => DateTime(2026, 3, 1),
      );
      await controller.load();
    });

    test('toggling persists and reaches the engine', () async {
      await controller.setCategory(ProtectionCategory.drugs, false);
      await controller.setEnabled(false);

      final reloaded = ProtectionController(
        repository: LocalProtectionRepository(store),
        engine: engine,
      );
      await reloaded.load();
      expect(reloaded.state.enabled, isFalse);
      expect(reloaded.state.isActive(ProtectionCategory.drugs), isFalse);
      expect(reloaded.state.updatedAt, DateTime(2026, 3, 1));
      // The latest policy reached the native side.
      expect(engine.applied!.enabled, isFalse);
      expect(engine.applied!.isActive(ProtectionCategory.drugs), isFalse);
    });

    test('no-op changes do not write', () async {
      final applies = engine.appliedStates.length;
      await controller.setCategory(ProtectionCategory.drugs, true);
      expect(store.values, isEmpty);
      expect(engine.appliedStates, hasLength(applies));
    });

    test('rolls back when saving fails', () async {
      store.failWith = Exception('disk full');
      final result = await controller.setEnabled(false);
      expect(result.failureOrNull, isA<StorageFailure>());
      expect(controller.state.enabled, isTrue);
    });

    test('notifies listeners on change', () async {
      var calls = 0;
      controller.addListener(() => calls++);
      await controller.setCategory(ProtectionCategory.gore, false);
      expect(calls, greaterThan(0));
    });
  });

  group('SettingsController', () {
    test('defaults, persistence and reload', () async {
      final store = MemoryStore();
      final c = SettingsController(LocalSettingsRepository(store));
      await c.load();
      expect(c.settings, const AppSettings());
      expect(c.settings.theme, ThemePreference.dark);
      expect(c.settings.appLockEnabled, isTrue);

      await c.completeOnboarding();
      await c.setTheme(ThemePreference.light);
      await c.setAppLock(false);

      final again = SettingsController(LocalSettingsRepository(store));
      await again.load();
      expect(again.settings.onboardingCompleted, isTrue);
      expect(again.settings.theme, ThemePreference.light);
      expect(again.settings.appLockEnabled, isFalse);
    });

    test('tolerates unknown and missing fields', () {
      final s = AppSettings.fromJson({'theme': 'neon', 'extra': 1});
      expect(s.theme, ThemePreference.dark);
      expect(s.appLockEnabled, isTrue);
    });

    test('rolls back on storage failure', () async {
      final store = MemoryStore();
      final c = SettingsController(LocalSettingsRepository(store));
      await c.load();
      store.failWith = Exception('io');
      final r = await c.setTheme(ThemePreference.light);
      expect(r.isOk, isFalse);
      expect(c.settings.theme, ThemePreference.dark);
    });
  });
}
