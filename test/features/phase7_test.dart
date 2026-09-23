import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/protection/data/local_protection_repository.dart';
import 'package:safeguard/features/protection/domain/protection.dart';
import 'package:safeguard/features/protection/presentation/protection_controller.dart';

import '../support/fake_protection_engine.dart';

/// Counts start() calls; everything else behaves like the fake.
class _CountingEngine extends FakeProtectionEngine {
  _CountingEngine() : super(permissionGranted: true);
  int starts = 0;

  @override
  Future<void> start() {
    starts++;
    return super.start();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('state sync (Phase 7 review fixes)', () {
    Future<(ProtectionController, _CountingEngine)> coldStart({
      required bool safeMode,
      bool paused = false,
    }) async {
      final store = MemoryStore();
      await LocalProtectionRepository(store)
          .save(ProtectionState.initial().copyWith(enabled: true));
      final engine = _CountingEngine()..safeMode = safeMode;
      if (paused) await engine.startPause(5);
      final controller = ProtectionController(
        repository: LocalProtectionRepository(store),
        engine: engine,
      );
      await controller.load();
      return (controller, engine);
    }

    test('opening the app does not leave Safe Mode', () async {
      final (_, engine) = await coldStart(safeMode: true);
      expect(engine.starts, 0);
      expect(engine.current.vpnState, VpnState.stopped);
    });

    test('opening the app does not end a pause', () async {
      final (_, engine) = await coldStart(safeMode: false, paused: true);
      expect(engine.starts, 0);
    });

    test('a normally stopped VPN is still resumed on open', () async {
      final (_, engine) = await coldStart(safeMode: false);
      expect(engine.starts, 1);
      expect(engine.current.vpnState, VpnState.running);
    });
  });
}
