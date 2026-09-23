import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/app/app_dependencies.dart';
import 'package:safeguard/app/safeguard_app.dart';
import 'package:safeguard/core/platform/protection_channel.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/advanced/domain/settings_export.dart';
import 'package:safeguard/features/protection/data/local_protection_repository.dart';
import 'package:safeguard/features/protection/data/native_protection_engine.dart';
import 'package:safeguard/features/protection/domain/protection.dart';
import 'package:safeguard/features/protection/presentation/protection_controller.dart';
import 'package:safeguard/features/settings/domain/app_settings.dart';

import '../app/app_flow_test.dart' show enterPin, testDependencies;
import '../support/fake_protection_engine.dart';

const _pin = '739154';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 5 models', () {
    test('mode changes need the PIN except NORMAL → STRICT', () {
      expect(
        ProtectionMode.changeNeedsPin(
          ProtectionMode.normal,
          ProtectionMode.strict,
        ),
        isFalse,
      );
      expect(
        ProtectionMode.changeNeedsPin(
          ProtectionMode.strict,
          ProtectionMode.normal,
        ),
        isTrue,
      );
      expect(
        ProtectionMode.changeNeedsPin(
          ProtectionMode.normal,
          ProtectionMode.custom,
        ),
        isTrue,
      );
      expect(
        ProtectionMode.changeNeedsPin(
          ProtectionMode.custom,
          ProtectionMode.strict,
        ),
        isTrue,
      );
    });

    test('state: mode round-trips; old data loads as CUSTOM', () {
      final s = ProtectionState.initial()
          .withCategory(ProtectionCategory.drugs, false, DateTime(2026))
          .copyWith(mode: ProtectionMode.strict);
      final back = ProtectionState.fromJson(
        jsonDecode(s.encode()) as Map<String, dynamic>,
      );
      expect(back.mode, ProtectionMode.strict);
      expect(back.isChosen(ProtectionCategory.drugs), isFalse);
      // Presets enforce every category, whatever the user chose.
      expect(back.isActive(ProtectionCategory.drugs), isTrue);
      expect(
        ProtectionState.fromJson({
          'enabled': true,
          'categories': <String, dynamic>{},
        }).mode,
        ProtectionMode.custom,
      );
      expect(ProtectionState.initial().mode, ProtectionMode.custom);
    });

    test('health report parsing is defensive', () {
      final r = HealthReport.fromMap({
        'overall': 'partially_protected',
        'reason': 'dns:private_dns',
        'layers': [
          {'layer': 'vpn', 'state': 'active'},
          {'layer': 'dns', 'state': 'degraded', 'reason': 'private_dns'},
          {'layer': 'nonsense', 'state': 'active'},
          'garbage',
        ],
        'mode': 'strict',
        'pausedRemainingMs': 99999999999,
        'safeMode': false,
        'incidents': [
          {'timestamp': 5, 'kind': 'vpn_revoked'},
          {'timestamp': 6, 'kind': 'unknown_kind'},
        ],
      });
      expect(r.overall, OverallHealth.partiallyProtected);
      expect(r.layers, hasLength(2));
      expect(r.layer(HealthLayer.dns)!.state, LayerState.degraded);
      expect(r.mode, ProtectionMode.strict);
      expect(r.pausedRemaining, const Duration(minutes: 30)); // clamped
      expect(r.incidents.single.kind, IncidentKind.vpnRevoked);
      expect(HealthReport.fromMap(const {}).overall, OverallHealth.unknown);
    });

    test('window statistics parse sources, categories and custom', () {
      final w = WindowStats.fromMap({
        'total': 9,
        'bySource': {'dns': 4, 'search': 2, 'ai': 3, 'weird': 1},
        'byCategory': {'sexual': 5, 'custom': 2, 'bogus': 1},
        'falsePositiveReports': 1,
      });
      expect(w.source(EventSourceKind.dns), 4);
      expect(w.source(EventSourceKind.ai), 3);
      expect(w.byCategory, {ProtectionCategory.sexual: 5});
      expect(w.customCategoryCount, 2);
      expect(WindowStats.fromMap('nope').total, 0);
    });
  });

  group('Phase 5 channel contract', () {
    const method = MethodChannel(ProtectionChannel.methodChannelName);
    final calls = <MethodCall>[];
    late NativeProtectionEngine engine;

    setUp(() {
      calls.clear();
      engine = NativeProtectionEngine(ProtectionChannel(methods: method));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (call) async {
            calls.add(call);
            final health = {
              'overall': 'protected',
              'layers': <Object>[],
              'mode': 'normal',
              'pausedRemainingMs': 0,
              'safeMode': false,
              'incidents': <Object>[],
            };
            return switch (call.method) {
              'getHealth' ||
              'startPause' ||
              'endPause' ||
              'enterSafeMode' ||
              'resetProtection' => health,
              'addAllowedDomain' => {
                'domain': 'example.com',
                'action': 'allow',
                'includeSubdomains':
                    (call.arguments as Map)['includeSubdomains'],
              },
              'addBlockedDomain' => {
                'domain': 'example.com',
                'action': 'block',
                'category': (call.arguments as Map)['category'],
              },
              'getKeywords' => [
                {'id': 1, 'keyword': 'dark market', 'category': 'drugs'},
                {'id': 'x'},
              ],
              'addKeyword' => {
                'id': 2,
                'keyword': 'glitter',
                'category': (call.arguments as Map)['category'],
              },
              'getDetailedStatistics' => {
                'today': {'total': 1},
                'last7Days': {'total': 2},
                'last30Days': {'total': 3},
              },
              'saveExport' => {'status': 'cancelled'},
              'tryRecover' => true,
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, null);
    });

    test('allowlist scope and the custom category travel to native', () async {
      final a = await engine.addAllowedDomain(
        'example.com',
        includeSubdomains: true,
      );
      expect(calls.last.arguments, {
        'domain': 'example.com',
        'includeSubdomains': true,
      });
      expect(a.includeSubdomains, isTrue);
      final b = await engine.addBlockedDomain('example.com', null);
      expect((calls.last.arguments as Map)['category'], 'custom');
      expect(b.category, isNull);
    });

    test('pause, safe mode, reset, recover, stats, keywords, export', () async {
      await engine.startPause(10);
      expect(calls.last.arguments, {'minutes': 10});
      await engine.enterSafeMode();
      await engine.resetProtection();
      expect(await engine.tryRecover(), isTrue);
      final stats = await engine.detailedStatistics();
      expect(stats.last30Days.total, 3);
      final kws = await engine.keywords();
      expect(kws.single.keyword, 'dark market');
      final k = await engine.addKeyword('glitter', null);
      expect((calls.last.arguments as Map)['category'], 'custom');
      expect(k.category, isNull);
      expect(await engine.saveExport('{}'), ExportResult.cancelled);
      expect(
        calls.map((c) => c.method),
        containsAll(['enterSafeMode', 'resetProtection']),
      );
    });
  });

  group('Settings export', () {
    test('contains settings and lists, never secrets or logs', () {
      final data = SettingsExport.build(
        state: ProtectionState.initial().copyWith(mode: ProtectionMode.strict),
        search: const SearchSettings(),
        ai: const AiSettings(),
        app: const AppSettings(protectionLocked: true),
        blocked: const [DomainRule(domain: 'a.test', action: RuleAction.block)],
        allowed: const [
          DomainRule(
            domain: 'b.test',
            action: RuleAction.allow,
            includeSubdomains: false,
          ),
        ],
        keywords: const [CustomKeyword(id: 1, keyword: 'glitter')],
        protectedApps: const [
          InstalledApp(packageName: 'com.example.game', label: 'Game'),
        ],
        appVersion: '1.4.0',
        now: DateTime.utc(2026, 9, 23),
      );
      final json = SettingsExport.encode(data);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['format'], 'safeguard-settings');
      expect((decoded['protection'] as Map)['mode'], 'strict');
      expect((decoded['locks'] as Map)['protectionLock'], isTrue);
      final blocked = (decoded['blockedDomains'] as List)
          .cast<Map<String, dynamic>>();
      expect(blocked.single['category'], 'custom');
      final allowed = (decoded['allowedDomains'] as List)
          .cast<Map<String, dynamic>>();
      expect(allowed.single['includeSubdomains'], isFalse);
      expect(decoded['protectedApps'], ['com.example.game']);
      // Nothing secret: no field anywhere is PIN material, a key, a log or a
      // statistic (the "notIncluded" list only names what was left out).
      final keys = <String>{};
      void walk(Object? v) {
        if (v is Map) {
          for (final e in v.entries) {
            keys.add('${e.key}'.toLowerCase());
            walk(e.value);
          }
        } else if (v is List) {
          v.forEach(walk);
        }
      }

      walk(decoded);
      const bad = ['pin', 'hash', 'salt', 'secret', 'token', 'log', 'event'];
      for (final k in keys) {
        for (final b in bad) {
          expect(k.contains(b), isFalse, reason: k);
        }
      }
    });
  });

  group('ProtectionController Phase 5', () {
    Future<(ProtectionController, FakeProtectionEngine)> make() async {
      final engine = FakeProtectionEngine(permissionGranted: true);
      final c = ProtectionController(
        repository: LocalProtectionRepository(MemoryStore()),
        engine: engine,
      );
      await c.load();
      await engine.start();
      await c.refreshStatus();
      return (c, engine);
    }

    test('mode reaches native with the user categories', () async {
      final (c, engine) = await make();
      await c.setCategory(ProtectionCategory.gambling, false);
      await c.setMode(ProtectionMode.strict);
      expect(engine.applied!.mode, ProtectionMode.strict);
      // The stored choice is kept for when the user returns to CUSTOM.
      expect(engine.applied!.isChosen(ProtectionCategory.gambling), isFalse);
      expect(c.state.isActive(ProtectionCategory.gambling), isTrue);
      c.dispose();
    });

    test('pause counts down and suspends; ending it resumes', () async {
      final (c, engine) = await make();
      expect(c.health, ProtectionHealth.active);
      await c.startPause(5);
      expect(c.isPaused, isTrue);
      expect(c.health, ProtectionHealth.suspended);
      expect(engine.logs.first.source, EventSourceKind.manual);
      expect(engine.logs.first.isBlock, isFalse);
      await c.endPause();
      expect(c.isPaused, isFalse);
      expect(c.health, ProtectionHealth.active);
      c.dispose();
    });

    test('partial health is not reported as fully active', () async {
      final (c, engine) = await make();
      engine.overall = OverallHealth.partiallyProtected;
      await c.refreshHealth();
      expect(c.health, ProtectionHealth.partial);
      c.dispose();
    });

    test('resume asks native to recover', () async {
      final (c, engine) = await make();
      await c.onResume();
      expect(engine.recoverCalls, 1);
      c.dispose();
    });

    test('reset restores secure defaults but keeps protection on', () async {
      final (c, engine) = await make();
      await c.setMode(ProtectionMode.strict);
      await c.setCategory(ProtectionCategory.drugs, false);
      await c.resetProtection();
      expect(engine.resets, 1);
      expect(c.state.mode, ProtectionMode.custom);
      expect(c.state.isChosen(ProtectionCategory.drugs), isTrue);
      expect(c.state.enabled, isTrue);
      c.dispose();
    });
  });

  group('Phase 5 screens', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first
        ..physicalSize = const Size(1080, 2340)
        ..devicePixelRatio = 3;
    });

    Future<(FakeProtectionEngine, AppDependencies)> launch(
      WidgetTester tester, {
      FakeProtectionEngine? engine,
      bool locked = false,
    }) async {
      final e = engine ?? FakeProtectionEngine(permissionGranted: true);
      final prefs = MemoryStore();
      final secure = MemoryStore();
      final seed = testDependencies(prefs: prefs, secure: secure, engine: e);
      await seed.initialize();
      await seed.security.createPin(_pin, _pin);
      await seed.settings.completeOnboarding();
      await seed.settings.setAppLock(false);
      if (locked) await seed.settings.setProtectionLock(true);
      final deps = testDependencies(prefs: prefs, secure: secure, engine: e);
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await e.start();
      await tester.pumpAndSettle();
      return (e, deps);
    }

    Future<void> openSettingsEntry(WidgetTester tester, String entry) async {
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(entry),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
    }

    Future<void> scrollTo(WidgetTester tester, Finder f) async {
      await tester.scrollUntilVisible(
        f,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
    }

    testWidgets('dashboard shows mode, layers, apps and blocked today', (
      tester,
    ) async {
      final engine = FakeProtectionEngine(permissionGranted: true);
      engine.protected.add(
        const ProtectedApp(packageName: 'com.example.game', label: 'Game'),
      );
      await launch(tester, engine: engine);
      await scrollTo(tester, find.text('المحجوب اليوم'));
      expect(find.text('محمي بالكامل'), findsOneWidget);
      expect(find.text('الذكاء الاصطناعي'), findsOneWidget);
      expect(find.text('التطبيقات المحمية'), findsOneWidget);
    });

    testWidgets('NORMAL → STRICT is free; back to NORMAL needs the PIN', (
      tester,
    ) async {
      final (engine, deps) = await launch(tester);
      await scrollTo(tester, find.text('صارم'));
      await tester.tap(find.text('عادي'));
      await tester.pumpAndSettle();
      // CUSTOM → NORMAL needs the PIN.
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, _pin);
      expect(deps.protection.state.mode, ProtectionMode.normal);

      await scrollTo(tester, find.text('صارم'));
      await tester.tap(find.text('صارم'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsNothing);
      expect(engine.applied!.mode, ProtectionMode.strict);

      await scrollTo(tester, find.text('عادي'));
      await tester.tap(find.text('عادي'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await tester.tap(find.byTooltip('إلغاء'));
      await tester.pumpAndSettle();
      expect(deps.protection.state.mode, ProtectionMode.strict);
    });

    testWidgets('presets lock the category switches', (tester) async {
      final (_, deps) = await launch(tester);
      await deps.protection.setMode(ProtectionMode.strict);
      await tester.pumpAndSettle();
      final gambling = find.byKey(const ValueKey('category-gambling'));
      await scrollTo(tester, gambling);
      await tester.tap(gambling);
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsNothing);
      expect(
        deps.protection.state.isActive(ProtectionCategory.gambling),
        isTrue,
      );
      // The section header is above the categories: scroll back up.
      await tester.scrollUntilVisible(
        find.text('يحددها الوضع'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('يحددها الوضع'), findsOneWidget);
    });

    testWidgets('Protection Lock: even tightening needs the PIN', (
      tester,
    ) async {
      final (_, deps) = await launch(tester, locked: true);
      await deps.protection.setCategory(ProtectionCategory.drugs, false);
      await tester.pumpAndSettle();
      final drugs = find.descendant(
        of: find.byKey(const ValueKey('category-drugs')),
        matching: find.byType(Switch),
      );
      await scrollTo(tester, drugs);
      await tester.tap(drugs); // re-enable: tightening
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, _pin);
      expect(deps.protection.state.isActive(ProtectionCategory.drugs), isTrue);
    });

    testWidgets('turning Protection Lock off needs the PIN; on does not', (
      tester,
    ) async {
      final (_, deps) = await launch(tester);
      await openSettingsEntry(tester, 'قفل إعدادات الحماية');
      expect(find.text('أدخل رمز PIN'), findsNothing);
      expect(deps.settings.settings.protectionLocked, isTrue);
      await tester.tap(find.text('قفل إعدادات الحماية'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, _pin);
      expect(deps.settings.settings.protectionLocked, isFalse);
    });

    testWidgets('temporary unlock: PIN, countdown, resume', (tester) async {
      final (engine, deps) = await launch(tester);
      await openSettingsEntry(tester, 'إيقاف مؤقت للحماية');
      await tester.tap(find.text('10 دقائق'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, _pin);
      expect(engine.pausedFor, const Duration(minutes: 10));
      expect(deps.protection.isPaused, isTrue);
      expect(find.textContaining('تُستأنف بعد'), findsOneWidget);

      await tester.tap(find.text('الحماية').last);
      await tester.pumpAndSettle();
      expect(find.text('الحماية متوقفة مؤقتًا'), findsOneWidget);
      await tester.tap(find.text('استئناف الحماية الآن'));
      await tester.pumpAndSettle();
      expect(deps.protection.isPaused, isFalse);
      expect(engine.pausedFor, Duration.zero);
    });

    testWidgets('temporary unlock cannot start without the PIN', (
      tester,
    ) async {
      final (engine, _) = await launch(tester);
      await openSettingsEntry(tester, 'إيقاف مؤقت للحماية');
      await tester.tap(find.text('5 دقائق'));
      await tester.pumpAndSettle();
      await enterPin(tester, '111222');
      expect(find.textContaining('الرمز غير صحيح'), findsOneWidget);
      await tester.tap(find.byTooltip('إلغاء'));
      await tester.pumpAndSettle();
      expect(engine.pausedFor, Duration.zero);
    });

    testWidgets('brute-forcing the PIN on a Phase 5 gate hits the lockout', (
      tester,
    ) async {
      final (engine, deps) = await launch(tester);
      await openSettingsEntry(tester, 'إيقاف مؤقت للحماية');
      await tester.tap(find.text('30 دقائق'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await enterPin(tester, '11122${i % 10}');
      }
      expect(find.textContaining('حاول مجددًا بعد'), findsOneWidget);
      // Even the right PIN is refused while locked out.
      await enterPin(tester, _pin);
      expect(engine.pausedFor, Duration.zero);
      expect(deps.protection.isPaused, isFalse);
      await tester.tap(find.byTooltip('إلغاء'));
      await tester.pumpAndSettle();
    });

    testWidgets('safe mode: explained, PIN, then re-enable', (tester) async {
      final (engine, deps) = await launch(tester);
      await openSettingsEntry(tester, 'وضع الأمان');
      expect(find.textContaining('لاستعادة الإنترنت'), findsOneWidget);
      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();
      await enterPin(tester, _pin);
      expect(engine.safeMode, isTrue);
      expect(deps.protection.health, ProtectionHealth.suspended);
      await tester.tap(find.text('الحماية').last);
      await tester.pumpAndSettle();
      expect(find.text('وضع الأمان مفعّل'), findsOneWidget);
      expect(find.text('إعادة تفعيل الحماية'), findsOneWidget);
    });

    testWidgets('interruption banner offers restart and can be dismissed', (
      tester,
    ) async {
      final engine = FakeProtectionEngine(permissionGranted: true)
        ..incidents.add(
          ProtectionIncident(DateTime(2026), IncidentKind.vpnRevoked),
        );
      await launch(tester, engine: engine);
      expect(find.text('انقطعت الحماية'), findsOneWidget);
      expect(find.textContaining('فُصل اتصال VPN'), findsOneWidget);
      expect(find.text('أعد تفعيل الحماية'), findsOneWidget);
      await tester.tap(find.text('تم'));
      await tester.pumpAndSettle();
      expect(find.text('انقطعت الحماية'), findsNothing);
      expect(engine.incidents, isEmpty);
    });

    testWidgets('keywords: validated add, removal needs the PIN', (
      tester,
    ) async {
      final (engine, _) = await launch(tester);
      await openSettingsEntry(tester, 'الكلمات المحظورة');
      await tester.tap(find.text('إضافة كلمة'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.tap(find.text('إضافة').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('قصيرة جدًا'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Glitter Bomb');
      await tester.tap(find.text('إضافة').last);
      await tester.pumpAndSettle();
      expect(engine.keywordList.single.keyword, 'glitter bomb');
      expect(engine.keywordList.single.category, isNull);
      expect(find.text('glitter bomb'), findsOneWidget);

      await tester.tap(find.byTooltip('إزالة'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, _pin);
      expect(engine.keywordList, isEmpty);
    });

    testWidgets(
      'blocklist defaults to the custom category; duplicates refused',
      (tester) async {
        final (engine, _) = await launch(tester);
        await openSettingsEntry(tester, 'النطاقات المحظورة');
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.text('إضافة نطاق'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'www.Example.com');
          await tester.tap(find.text('إضافة').last);
          await tester.pumpAndSettle();
        }
        expect(engine.rules.single.domain, 'example.com');
        expect(engine.rules.single.category, isNull);
        expect(find.textContaining('موجود في القائمة بالفعل'), findsOneWidget);
      },
    );

    testWidgets('allowlist entries are exact unless subdomains are chosen', (
      tester,
    ) async {
      final (engine, _) = await launch(tester);
      await openSettingsEntry(tester, 'النطاقات المسموحة');
      await enterPin(tester, _pin); // opening the allowlist
      await tester.tap(find.text('إضافة نطاق'));
      await tester.pumpAndSettle();
      expect(find.textContaining('وwww فقط'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'school.test');
      await tester.tap(find.text('إضافة').last);
      await tester.pumpAndSettle();
      expect(engine.rules.single.includeSubdomains, isFalse);

      await tester.tap(find.text('إضافة نطاق'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'library.test');
      await tester.tap(find.text('يشمل كل النطاقات الفرعية'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إضافة').last);
      await tester.pumpAndSettle();
      expect(
        engine.rules
            .firstWhere((r) => r.domain == 'library.test')
            .includeSubdomains,
        isTrue,
      );
    });

    testWidgets('statistics per period and source', (tester) async {
      final engine = FakeProtectionEngine(permissionGranted: true)
        ..detailed = const DetailedStats(
          today: WindowStats(
            total: 3,
            bySource: {EventSourceKind.dns: 2, EventSourceKind.ai: 1},
            byCategory: {ProtectionCategory.sexual: 3},
          ),
          last7Days: WindowStats(total: 12, falsePositiveReports: 2),
        );
      await launch(tester, engine: engine);
      await openSettingsEntry(tester, 'الإحصاءات');
      expect(find.text('3'), findsWidgets);
      expect(find.text('2'), findsWidgets);
      await tester.tap(find.text('7 أيام'));
      await tester.pumpAndSettle();
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('export needs the PIN and contains no PIN or logs', (
      tester,
    ) async {
      final (engine, _) = await launch(tester);
      engine.keywordList.add(const CustomKeyword(id: 1, keyword: 'glitter'));
      await openSettingsEntry(tester, 'تصدير الإعدادات');
      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, _pin);
      final json = engine.exported!;
      expect(json, contains('glitter'));
      expect(json, isNot(contains(_pin)));
      expect(json.toLowerCase(), isNot(contains('hash')));
    });

    testWidgets('reset protection needs confirmation and the PIN', (
      tester,
    ) async {
      final (engine, deps) = await launch(tester);
      await deps.protection.setMode(ProtectionMode.strict);
      await openSettingsEntry(tester, 'إعادة ضبط الحماية');
      await tester.tap(find.text('إعادة الضبط'));
      await tester.pumpAndSettle();
      await enterPin(tester, _pin);
      expect(engine.resets, 1);
      expect(deps.protection.state.mode, ProtectionMode.custom);
    });
  });
}
