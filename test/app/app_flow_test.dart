import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/app/app_dependencies.dart';
import 'package:safeguard/app/safeguard_app.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/pin/data/pin_data.dart';
import 'package:safeguard/features/protection/domain/protection.dart';

AppDependencies testDependencies({MemoryStore? prefs, MemoryStore? secure}) {
  return AppDependencies(
    preferences: prefs ?? MemoryStore(),
    secureStore: secure ?? MemoryStore(),
    hasher: const Pbkdf2PinHasher(iterations: 100, useIsolate: false),
  );
}

Future<void> enterPin(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.bySemanticsLabel(d).last);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first
      ..physicalSize = const Size(1080, 2340)
      ..devicePixelRatio = 3;
  });

  testWidgets('first run: onboarding → PIN → home, RTL throughout', (
    tester,
  ) async {
    final deps = testDependencies();
    await tester.pumpWidget(SafeGuardApp(dependencies: deps));
    await tester.pumpAndSettle();

    expect(find.text('إعداد رمز PIN'), findsOneWidget);
    // Regression: the pinned footer once collapsed the page body to 0px.
    expect(find.text('يعمل على جهازك').hitTestable(), findsOneWidget);
    final dir = Directionality.of(tester.element(find.text('إعداد رمز PIN')));
    expect(dir, TextDirection.rtl);

    await tester.tap(find.text('إعداد رمز PIN'));
    await tester.pumpAndSettle();
    expect(find.text('أنشئ رمز PIN'), findsOneWidget);

    // Weak PIN is refused with an explanation.
    await enterPin(tester, '123456');
    expect(find.textContaining('سهل التخمين'), findsOneWidget);

    await enterPin(tester, '739154');
    expect(find.text('أكّد الرمز'), findsOneWidget);
    await enterPin(tester, '739154');

    expect(find.text('الحماية مفعّلة'), findsOneWidget);
    expect(deps.settings.settings.onboardingCompleted, isTrue);
    expect(deps.security.pinSet, isTrue);
  });

  testWidgets('disabling a category requires the PIN; enabling does not', (
    tester,
  ) async {
    final deps = testDependencies();
    await tester.pumpWidget(SafeGuardApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إعداد رمز PIN'));
    await tester.pumpAndSettle();
    await enterPin(tester, '739154');
    await enterPin(tester, '739154');

    final gamblingSwitch = find.descendant(
      of: find.byKey(const ValueKey('category-gambling')),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(gamblingSwitch);
    await tester.pumpAndSettle();
    await tester.tap(gamblingSwitch);
    await tester.pumpAndSettle();

    // PIN gate is shown; a wrong PIN changes nothing.
    expect(find.text('أدخل رمز PIN'), findsOneWidget);
    await enterPin(tester, '111222');
    expect(find.textContaining('الرمز غير صحيح'), findsOneWidget);
    expect(deps.protection.state.isActive(ProtectionCategory.gambling), isTrue);

    await enterPin(tester, '739154');
    expect(
      deps.protection.state.isActive(ProtectionCategory.gambling),
      isFalse,
    );

    // Re-enabling is immediate.
    await tester.ensureVisible(gamblingSwitch);
    await tester.pumpAndSettle();
    await tester.tap(gamblingSwitch);
    await tester.pumpAndSettle();
    expect(find.text('أدخل رمز PIN'), findsNothing);
    expect(deps.protection.state.isActive(ProtectionCategory.gambling), isTrue);
  });

  testWidgets('returning user with app lock sees the lock screen', (
    tester,
  ) async {
    final prefs = MemoryStore();
    final secure = MemoryStore();
    final first = testDependencies(prefs: prefs, secure: secure);
    await first.initialize();
    await first.security.createPin('739154', '739154');
    await first.settings.completeOnboarding();

    await tester.pumpWidget(
      SafeGuardApp(
        dependencies: testDependencies(prefs: prefs, secure: secure),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('للمتابعة إلى SafeGuard'), findsOneWidget);

    await enterPin(tester, '739154');
    expect(find.text('الحماية مفعّلة'), findsOneWidget);
  });

  testWidgets('status and settings tabs render', (tester) async {
    final prefs = MemoryStore();
    final secure = MemoryStore();
    final seed = testDependencies(prefs: prefs, secure: secure);
    await seed.initialize();
    await seed.security.createPin('739154', '739154');
    await seed.settings.completeOnboarding();
    await seed.settings.setAppLock(false);

    await tester.pumpWidget(
      SafeGuardApp(
        dependencies: testDependencies(prefs: prefs, secure: secure),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('الحالة'));
    await tester.pumpAndSettle();
    expect(find.text('طبقات الحماية'), findsOneWidget);
    expect(find.text('غير متاحة بعد'), findsOneWidget);

    await tester.tap(find.text('الإعدادات').last);
    await tester.pumpAndSettle();
    expect(find.text('تغيير رمز PIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
