import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/app/app_dependencies.dart';
import 'package:safeguard/app/safeguard_app.dart';
import 'package:safeguard/core/platform/protection_channel.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/protection/data/native_protection_engine.dart';
import 'package:safeguard/features/protection/domain/protection.dart';

import '../app/app_flow_test.dart' show enterPin, testDependencies;
import '../support/fake_protection_engine.dart';

const _pin = '739154';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LogRetention', () {
    test('ids round-trip; unknown ids are rejected', () {
      for (final r in LogRetention.values) {
        expect(LogRetention.fromId(r.id), r);
      }
      expect(LogRetention.fromId('forever'), isNull);
      expect(LogRetention.fromId(null), isNull);
      expect(LogRetention.defaultValue, LogRetention.days30);
    });

    test('ordering: never < 7 days < 30 days', () {
      expect(LogRetention.never.isShorterThan(LogRetention.days7), isTrue);
      expect(LogRetention.days7.isShorterThan(LogRetention.days30), isTrue);
      expect(LogRetention.days30.isShorterThan(LogRetention.days7), isFalse);
    });
  });

  group('native channel contract (Phase 6)', () {
    const channel = MethodChannel('test/phase6');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'getLogRetention' => '7d',
              'setLogRetention' => (call.arguments as Map)['value'],
              'monotonicTime' => {'elapsedMs': 1234, 'boot': 9},
              _ => null,
            };
          });
    });

    test('retention get/set', () async {
      final engine = NativeProtectionEngine(
        ProtectionChannel(methods: channel),
      );
      expect(await engine.logRetention(), LogRetention.days7);
      expect(
        await engine.setLogRetention(LogRetention.never),
        LogRetention.never,
      );
      expect(calls.last.arguments, {'value': 'never'});
    });

    test('monotonic time for the PIN lockout', () async {
      final source = platformMonotonicSource(
        ProtectionChannel(methods: channel),
      );
      final r = await source();
      expect(r!.elapsedMs, 1234);
      expect(r.boot, 9);
    });

    test('missing boot id disables the monotonic path', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => {'elapsedMs': 1, 'boot': -1},
          );
      final source = platformMonotonicSource(
        ProtectionChannel(methods: channel),
      );
      expect(await source(), isNull);
    });
  });

  group('Phase 6 screens', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first
        ..physicalSize = const Size(1080, 2340)
        ..devicePixelRatio = 3;
    });

    Future<FakeProtectionEngine> launch(
      WidgetTester tester, {
      LogRetention retention = LogRetention.days30,
    }) async {
      final e = FakeProtectionEngine(permissionGranted: true)
        ..retention = retention;
      final prefs = MemoryStore();
      final secure = MemoryStore();
      final seed = testDependencies(prefs: prefs, secure: secure, engine: e);
      await seed.initialize();
      await seed.security.createPin(_pin, _pin);
      await seed.settings.completeOnboarding();
      await seed.settings.setAppLock(false);
      final deps = testDependencies(prefs: prefs, secure: secure, engine: e);
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      final tile = find.text('مدة الاحتفاظ بالسجل');
      await tester.scrollUntilVisible(
        tile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      return e;
    }

    testWidgets('shortening retention asks to confirm, then the PIN', (
      tester,
    ) async {
      final engine = await launch(tester);
      expect(find.text('30 يومًا'), findsOneWidget);
      await tester.tap(find.text('مدة الاحتفاظ بالسجل'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('7 أيام'));
      await tester.pumpAndSettle();
      expect(find.text('تقصير مدة السجل؟'), findsOneWidget);
      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();
      await enterPin(tester, _pin);
      expect(engine.retention, LogRetention.days7);
      expect(find.text('7 أيام'), findsOneWidget);
    });

    testWidgets('a wrong PIN leaves retention unchanged', (tester) async {
      final engine = await launch(tester);
      await tester.tap(find.text('مدة الاحتفاظ بالسجل'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('لا يُحفظ سجل'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();
      await enterPin(tester, '111222');
      expect(engine.retention, LogRetention.days30);
    });

    testWidgets('lengthening needs the PIN but no confirmation', (
      tester,
    ) async {
      final engine = await launch(tester, retention: LogRetention.days7);
      await tester.tap(find.text('مدة الاحتفاظ بالسجل'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 يومًا').last);
      await tester.pumpAndSettle();
      expect(find.text('تقصير مدة السجل؟'), findsNothing);
      await enterPin(tester, _pin);
      expect(engine.retention, LogRetention.days30);
    });
  });
}
