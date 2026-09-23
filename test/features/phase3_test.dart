import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/app/safeguard_app.dart';
import 'package:safeguard/core/error/failures.dart';
import 'package:safeguard/core/platform/protection_channel.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/protection/data/local_protection_repository.dart';
import 'package:safeguard/features/protection/data/native_protection_engine.dart';
import 'package:safeguard/features/protection/domain/protection.dart';
import 'package:safeguard/features/protection/presentation/protection_controller.dart';

import '../app/app_flow_test.dart' show enterPin, testDependencies;
import '../support/fake_protection_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 3 platform channel contract', () {
    const method = MethodChannel(ProtectionChannel.methodChannelName);
    final calls = <MethodCall>[];
    late NativeProtectionEngine engine;

    setUp(() {
      calls.clear();
      engine = NativeProtectionEngine(ProtectionChannel(methods: method));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (call) async {
            calls.add(call);
            final args = call.arguments is Map
                ? call.arguments as Map
                : const {};
            return switch (call.method) {
              'getSearchSettings' => {
                'enabled': true,
                'google': false,
                'bing': true,
                'duckDuckGo': true,
                'youtube': 'moderate',
              },
              'setSearchSettings' => Map<String, Object?>.from(args),
              'submitSearch' => {
                'action': 'block',
                'category': 'gambling',
                'confidence': 0.9,
                'ruleType': 'keyword',
                'reason': 'category_blocked',
                'opened': false,
              },
              'getProtectedApps' => [
                {'packageName': 'com.a.b', 'label': 'AB', 'addedAt': 5},
                {'label': 'missing package'},
              ],
              'getLaunchableApps' => [
                {'packageName': 'com.c.d', 'label': 'CD'},
              ],
              'addProtectedApp' when args['packageName'] == 'bad' =>
                throw PlatformException(code: 'INVALID_PACKAGE'),
              'addProtectedApp' when args['packageName'] == 'com.x.missing' =>
                throw PlatformException(code: 'PACKAGE_NOT_INSTALLED'),
              'addProtectedApp' => {
                'packageName': args['packageName'],
                'label': 'Label',
                'addedAt': 9,
              },
              'removeProtectedApp' => true,
              'getAccessibilityStatus' => {'state': 'permission_denied'},
              'setAccessibilityDisclosure' => {
                'state': args['accepted'] == true
                    ? 'disabled'
                    : 'permission_denied',
              },
              'openAccessibilitySettings' => true,
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, null);
    });

    test('search settings: names, parameters and parsing', () async {
      final s = await engine.searchSettings();
      expect(calls.last.method, 'getSearchSettings');
      expect(s.google, isFalse);
      expect(s.youtube, YouTubeMode.moderate);

      await engine.setSearchSettings(s.copyWith(google: true));
      expect(calls.last.method, 'setSearchSettings');
      expect(calls.last.arguments, {
        'enabled': true,
        'google': true,
        'bing': true,
        'duckDuckGo': true,
        'youtube': 'moderate',
      });
    });

    test(
      'submitSearch sends query+engine and parses a decision without the query',
      () async {
        final r = await engine.submitSearch(
          'online casino',
          SearchEngineId.bing,
        );
        expect(calls.last.method, 'submitSearch');
        expect(calls.last.arguments, {
          'query': 'online casino',
          'engine': 'bing',
        });
        expect(r.blocked, isTrue);
        expect(r.category, ProtectionCategory.gambling);
        expect(r.confidence, 0.9);
        expect(r.opened, isFalse);
      },
    );

    test('protected apps and launchable apps', () async {
      final apps = await engine.protectedApps();
      expect(apps.single.packageName, 'com.a.b');
      expect(apps.single.addedAt, DateTime.fromMillisecondsSinceEpoch(5));
      expect((await engine.launchableApps()).single.label, 'CD');

      final added = await engine.addProtectedApp('com.c.d');
      expect(calls.last.arguments, {'packageName': 'com.c.d'});
      expect(added.label, 'Label');

      expect(await engine.removeProtectedApp('com.c.d'), isTrue);
      expect(calls.last.method, 'removeProtectedApp');
      expect(calls.last.arguments, {'packageName': 'com.c.d'});
    });

    test('error codes become typed failures', () async {
      await expectLater(
        engine.addProtectedApp('bad'),
        throwsA(
          isA<EngineFailure>().having((f) => f.code, 'code', 'INVALID_PACKAGE'),
        ),
      );
      await expectLater(
        engine.addProtectedApp('com.x.missing'),
        throwsA(
          isA<EngineFailure>().having(
            (f) => f.message,
            'message',
            contains('غير مثبت'),
          ),
        ),
      );
    });

    test('accessibility status mapping', () async {
      expect(
        await engine.accessibilityStatus(),
        AccessibilityStatus.permissionDenied,
      );
      expect(
        await engine.setAccessibilityDisclosure(accepted: true),
        AccessibilityStatus.disabled,
      );
      expect(calls.last.arguments, {'accepted': true});
      await engine.openAccessibilitySettings();
      expect(calls.last.method, 'openAccessibilitySettings');
      for (final (raw, expected) in [
        ('enabled', AccessibilityStatus.enabled),
        ('disabled', AccessibilityStatus.disabled),
        ('unavailable', AccessibilityStatus.unavailable),
        ('garbage', AccessibilityStatus.unavailable),
      ]) {
        expect(AccessibilityStatus.fromId(raw), expected);
      }
    });

    test('events carry source, confidence and rule type', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            method,
            (call) async => [
              {
                'timestamp': 1,
                'domain': 'ga07#3fa1c09e',
                'category': 'gambling',
                'source': 'search',
                'action': 'block',
                'confidence': 0.9,
                'ruleType': 'keyword',
              },
              {'timestamp': 2, 'domain': 'old.test', 'category': 'sexual'},
            ],
          );
      final logs = await engine.blockedLogs();
      expect(logs[0].source, EventSourceKind.search);
      expect(logs[0].confidence, 0.9);
      expect(logs[0].ruleType, 'keyword');
      // Phase 2 events without the new fields still parse.
      expect(logs[1].source, EventSourceKind.dns);
      expect(logs[1].ruleType, 'domain');
    });
  });

  group('SearchSettings', () {
    const all = SearchSettings();

    test('loosening is detected (these need the PIN)', () {
      expect(all.isLoosenedBy(all.copyWith(enabled: false)), isTrue);
      expect(all.isLoosenedBy(all.copyWith(google: false)), isTrue);
      expect(
        all.isLoosenedBy(all.copyWith(youtube: YouTubeMode.moderate)),
        isTrue,
      );
      expect(all.isLoosenedBy(all.copyWith(youtube: YouTubeMode.off)), isTrue);
    });

    test('tightening or no change is not loosening', () {
      final loose = all.copyWith(bing: false, youtube: YouTubeMode.off);
      expect(loose.isLoosenedBy(all), isFalse);
      expect(all.isLoosenedBy(all), isFalse);
    });

    test('fromMap tolerates missing and wrong types (defaults are strict)', () {
      final s = SearchSettings.fromMap({'google': 'yes', 'youtube': 42});
      expect(s, const SearchSettings());
    });
  });

  group('ProtectionController ↔ Search Protection', () {
    Future<(ProtectionController, FakeProtectionEngine)> make() async {
      final engine = FakeProtectionEngine(permissionGranted: true);
      final c = ProtectionController(
        repository: LocalProtectionRepository(MemoryStore()),
        engine: engine,
      );
      await c.load();
      return (c, engine);
    }

    test(
      'master switch and the Phase 1 search category stay in sync',
      () async {
        final (c, engine) = await make();
        expect(c.searchProtectionEnabled, isTrue);
        expect(engine.search.enabled, isTrue);

        await c.setSearchSettings(c.searchSettings.copyWith(enabled: false));
        expect(c.state.isActive(ProtectionCategory.unsafeSearch), isFalse);
        expect(engine.search.enabled, isFalse);

        await c.setCategory(ProtectionCategory.unsafeSearch, true);
        expect(engine.search.enabled, isTrue);
        expect(c.searchSettings.enabled, isTrue);
      },
    );

    test('per-engine settings reach the engine', () async {
      final (c, engine) = await make();
      await c.setSearchSettings(
        c.searchSettings.copyWith(youtube: YouTubeMode.moderate),
      );
      expect(engine.search.youtube, YouTubeMode.moderate);
      expect(engine.search.enabled, isTrue);
    });

    test('accessibility status is loaded and refreshed', () async {
      final (c, engine) = await make();
      expect(c.accessibility, AccessibilityStatus.disabled);
      engine.a11y = AccessibilityStatus.enabled;
      await c.refreshAppProtection();
      expect(c.accessibility, AccessibilityStatus.enabled);
    });
  });

  group('App protection rules (fake mirrors native validation)', () {
    late FakeProtectionEngine engine;
    setUp(() => engine = FakeProtectionEngine());

    test(
      'add, duplicate, invalid, not installed, not allowed, remove',
      () async {
        await engine.addProtectedApp('com.example.social');
        expect((await engine.protectedApps()).single.label, 'Social');
        for (final (pkg, code) in [
          ('com.example.social', 'DUPLICATE_PACKAGE'),
          ('not a package', 'INVALID_PACKAGE'),
          ('com.not.installed', 'PACKAGE_NOT_INSTALLED'),
          ('com.android.settings', 'PACKAGE_NOT_ALLOWED'),
        ]) {
          await expectLater(
            engine.addProtectedApp(pkg),
            throwsA(isA<EngineFailure>().having((f) => f.code, 'code', code)),
            reason: pkg,
          );
        }
        expect(await engine.removeProtectedApp('com.example.social'), isTrue);
        expect(await engine.removeProtectedApp('com.example.social'), isFalse);
      },
    );
  });

  group('Phase 3 screens', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first
        ..physicalSize = const Size(1080, 2340)
        ..devicePixelRatio = 3;
    });

    Future<FakeProtectionEngine> open(WidgetTester tester, String entry) async {
      final engine = FakeProtectionEngine(permissionGranted: true);
      final prefs = MemoryStore();
      final secure = MemoryStore();
      final seed = testDependencies(
        prefs: prefs,
        secure: secure,
        engine: engine,
      );
      await seed.initialize();
      await seed.security.createPin('739154', '739154');
      await seed.settings.completeOnboarding();
      await seed.settings.setAppLock(false);
      await tester.pumpWidget(
        SafeGuardApp(
          dependencies: testDependencies(
            prefs: prefs,
            secure: secure,
            engine: engine,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(entry), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
      return engine;
    }

    testWidgets(
      'blocked search shows the block screen; the query is never logged',
      (tester) async {
        final engine = await open(tester, 'حماية البحث');
        final box = find.byType(TextField);
        await tester.scrollUntilVisible(
          box,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.enterText(box, 'best online casino near me');
        // Typing alone triggers nothing (analysis runs on submit only).
        expect(engine.submittedEngines, isEmpty);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        expect(find.text('تم حظر هذا المحتوى'), findsOneWidget);
        expect(
          find.textContaining('المقامرة', findRichText: true),
          findsOneWidget,
        );
        expect(engine.logs, hasLength(1));
        final e = engine.logs.single;
        expect(e.source, EventSourceKind.search);
        expect(e.domain, isNot(contains('casino')));
        expect(e.domain, isNot(contains('near')));
      },
    );

    testWidgets('allowed search opens results, no block screen', (
      tester,
    ) async {
      final engine = await open(tester, 'حماية البحث');
      final box = find.byType(TextField);
      await tester.scrollUntilVisible(
        box,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(box, 'weather tomorrow');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('تم حظر هذا المحتوى'), findsNothing);
      expect(engine.submittedEngines, [SearchEngineId.google]);
      expect(engine.logs, isEmpty);
    });

    testWidgets(
      'turning SafeSearch off needs the PIN; turning it on does not',
      (tester) async {
        final engine = await open(tester, 'حماية البحث');
        final google = find.descendant(
          of: find
              .ancestor(of: find.text('Google'), matching: find.byType(InkWell))
              .first,
          matching: find.byType(Switch),
        );
        await tester.tap(google);
        await tester.pumpAndSettle();
        expect(find.text('أدخل رمز PIN'), findsOneWidget);
        await enterPin(tester, '739154');
        expect(engine.search.google, isFalse);

        await tester.tap(google);
        await tester.pumpAndSettle();
        expect(find.text('أدخل رمز PIN'), findsNothing);
        expect(engine.search.google, isTrue);
      },
    );

    testWidgets(
      'disabling Search Protection needs the PIN and can be cancelled',
      (tester) async {
        final engine = await open(tester, 'حماية البحث');
        final master = find.byType(Switch).first;
        await tester.tap(master);
        await tester.pumpAndSettle();
        expect(find.text('أدخل رمز PIN'), findsOneWidget);
        await tester.tap(find.byTooltip('إلغاء'));
        await tester.pumpAndSettle();
        expect(engine.search.enabled, isTrue);
      },
    );

    testWidgets(
      'accessibility: decline → denied; accept → opens Android settings',
      (tester) async {
        final engine = await open(tester, 'حماية التطبيقات');
        expect(find.text('غير مفعّلة'), findsOneWidget);

        await tester.tap(find.text('تفعيل الخدمة'));
        await tester.pumpAndSettle();
        expect(find.textContaining('لا تقرأ محتوى الشاشة'), findsOneWidget);
        await tester.tap(find.text('لا أوافق'));
        await tester.pumpAndSettle();
        expect(engine.a11y, AccessibilityStatus.permissionDenied);
        expect(find.text('مرفوضة'), findsOneWidget);
        expect(engine.accessibilitySettingsOpened, 0);

        await tester.tap(find.text('تفعيل الخدمة'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('موافق، افتح الإعدادات'));
        await tester.pumpAndSettle();
        expect(engine.accessibilitySettingsOpened, 1);
      },
    );

    testWidgets('accessibility enabled and unavailable states render', (
      tester,
    ) async {
      final engine = FakeProtectionEngine(permissionGranted: true)
        ..a11y = AccessibilityStatus.unavailable;
      final prefs = MemoryStore();
      final secure = MemoryStore();
      final seed = testDependencies(
        prefs: prefs,
        secure: secure,
        engine: engine,
      );
      await seed.initialize();
      await seed.security.createPin('739154', '739154');
      await seed.settings.completeOnboarding();
      await seed.settings.setAppLock(false);
      await tester.pumpWidget(
        SafeGuardApp(
          dependencies: testDependencies(
            prefs: prefs,
            secure: secure,
            engine: engine,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('حماية التطبيقات'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('حماية التطبيقات'));
      await tester.pumpAndSettle();
      expect(find.textContaining('إعداد مقيّد'), findsOneWidget);
      expect(find.text('تفعيل الخدمة'), findsNothing);
    });

    testWidgets('add a protected app freely; removing needs the PIN', (
      tester,
    ) async {
      final engine = await open(tester, 'حماية التطبيقات');
      await tester.tap(find.text('إضافة تطبيق'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Social'));
      await tester.pumpAndSettle();
      expect(engine.protected.single.packageName, 'com.example.social');
      await tester.scrollUntilVisible(
        find.text('com.example.social'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('com.example.social'), findsOneWidget);

      await tester.tap(find.byTooltip('إزالة'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, '739154');
      expect(engine.protected, isEmpty);
      await tester.scrollUntilVisible(
        find.text('لا توجد تطبيقات محمية'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('لا توجد تطبيقات محمية'), findsOneWidget);
    });

    testWidgets(
      'an app the content shield covers asks before blocking it all',
      (tester) async {
        final engine = await open(tester, 'حماية التطبيقات');
        engine.installed.add(
          const InstalledApp(packageName: 'pkg.instagram', label: 'Instagram'),
        );
        Future<void> pick() async {
          await tester.tap(find.text('إضافة تطبيق'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Instagram'));
          await tester.pumpAndSettle();
        }

        await pick();
        expect(find.text('هذا يمنع فتح التطبيق كله'), findsOneWidget);
        expect(find.textContaining('درع المحتوى'), findsOneWidget);
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        expect(engine.protected, isEmpty);

        await pick();
        await tester.tap(find.text('منع التطبيق كله'));
        await tester.pumpAndSettle();
        expect(engine.protected.single.packageName, 'pkg.instagram');
      },
    );
  });
}
