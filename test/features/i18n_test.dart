import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:safeguard/app/router/routes.dart';
import 'package:safeguard/app/safeguard_app.dart';
import 'package:safeguard/core/error/failures.dart';
import 'package:safeguard/core/i18n/i18n.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/core/utils/arabic_format.dart';
import 'package:safeguard/features/protection/domain/protection.dart';

import '../app/app_flow_test.dart' show testDependencies;
import '../support/fake_protection_engine.dart';

const _pin = '739154';
final _arabic = RegExp('[؀-ۿ]');

/// Every string currently rendered (Text and RichText).
List<String> _visibleStrings(WidgetTester tester) => [
  for (final w in tester.widgetList<RichText>(find.byType(RichText)))
    w.text.toPlainText(),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => I18n.current = AppLanguage.ar);

  group('tr / formatting', () {
    test('tr picks by the current language', () {
      I18n.current = AppLanguage.ar;
      expect(tr('نعم', 'Yes'), 'نعم');
      I18n.current = AppLanguage.en;
      expect(tr('نعم', 'Yes'), 'Yes');
      expect(AppLanguage.en.direction, TextDirection.ltr);
      expect(AppLanguage.ar.direction, TextDirection.rtl);
      expect(AppLanguage.fromName('xx'), AppLanguage.ar);
    });

    test('relative time in both languages', () {
      final now = DateTime(2026, 1, 1, 12);
      I18n.current = AppLanguage.en;
      expect(
        ArabicFormat.relative(
          now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        '5 minutes ago',
      );
      expect(
        ArabicFormat.relative(now.subtract(const Duration(hours: 1)), now: now),
        '1 hour ago',
      );
      I18n.current = AppLanguage.ar;
      expect(
        ArabicFormat.relative(now.subtract(const Duration(hours: 2)), now: now),
        'قبل ساعتين',
      );
    });

    test('failure messages follow the language at display time', () {
      I18n.current = AppLanguage.ar;
      const failure = EngineFailure('INVALID_DOMAIN');
      expect(_arabic.hasMatch(failure.message), isTrue);
      I18n.current = AppLanguage.en;
      expect(failure.message, "This isn't a valid domain name.");
    });
  });

  group('English UI', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first
        ..physicalSize = const Size(1080, 2340)
        ..devicePixelRatio = 3;
    });

    Future<void> launch(WidgetTester tester) async {
      final engine = FakeProtectionEngine(permissionGranted: true);
      engine.protected.add(
        const ProtectedApp(packageName: 'com.example.game', label: 'Game'),
      );
      final prefs = MemoryStore();
      final secure = MemoryStore();
      final seed = testDependencies(
        prefs: prefs,
        secure: secure,
        engine: engine,
      );
      await seed.initialize();
      await seed.security.createPin(_pin, _pin);
      await seed.settings.completeOnboarding();
      await seed.settings.setAppLock(false);
      await seed.settings.setLanguage(AppLanguage.en);
      final deps = testDependencies(
        prefs: prefs,
        secure: secure,
        engine: engine,
      );
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await engine.start();
      await tester.pumpAndSettle();
    }

    void expectNoArabic(WidgetTester tester, String where) {
      final leaks = _visibleStrings(tester)
          .where(_arabic.hasMatch)
          // The language picker names Arabic in Arabic on purpose.
          .where((s) => s != 'العربية')
          .toList();
      expect(leaks, isEmpty, reason: 'Arabic text on $where: $leaks');
    }

    testWidgets('every main screen is fully English and LTR', (tester) async {
      await launch(tester);
      final routes = [
        Routes.home,
        Routes.status,
        Routes.settings,
        Routes.blocklist,
        Routes.allowlist,
        Routes.activity,
        Routes.searchProtection,
        Routes.appProtection,
        Routes.aiProtection,
        Routes.keywords,
        Routes.statistics,
        '${Routes.blocked}?category=gambling',
      ];
      for (final route in routes) {
        final context = tester.element(find.byType(Navigator).first);
        GoRouter.of(context).go(route);
        await tester.pumpAndSettle();
        expect(
          _visibleStrings(tester).where((t) => t.trim().isNotEmpty),
          isNotEmpty,
          reason: route,
        );
        final scrollables = find.byType(Scrollable);
        // Scroll through long pages so lazily built rows are checked too.
        for (var i = 0; i < 12; i++) {
          expectNoArabic(tester, route);
          if (scrollables.evaluate().isEmpty) break;
          await tester.drag(scrollables.first, const Offset(0, -600));
          await tester.pumpAndSettle();
        }
        final dir = Directionality.of(
          tester.element(find.byType(Scaffold).last),
        );
        expect(dir, TextDirection.ltr, reason: route);
      }
    });

    testWidgets('switching language in Settings updates open pages', (
      tester,
    ) async {
      await launch(tester);
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Language'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('العربية').last);
      await tester.pumpAndSettle();
      expect(find.text('اللغة'), findsOneWidget);
      expect(find.text('Language'), findsNothing);
      final dir = Directionality.of(tester.element(find.text('اللغة')));
      expect(dir, TextDirection.rtl);
    });
  });
}
