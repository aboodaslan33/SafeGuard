import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/app/app_info.dart';
import 'package:safeguard/app/safeguard_app.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/diagnostics/domain/diagnostic_report.dart';
import 'package:safeguard/features/protection/data/local_protection_repository.dart';
import 'package:safeguard/features/protection/domain/protection.dart';
import 'package:safeguard/features/protection/presentation/protection_controller.dart';
import 'package:safeguard/features/setup/domain/setup_checks.dart';
import 'package:safeguard/features/setup/presentation/setup_wizard_screen.dart';

import '../app/app_flow_test.dart'
    show createPinAndSkipWizard, enterPin, openPinSetup, testDependencies;
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

  group('setup checks', () {
    SetupFacts facts({
      bool permission = true,
      VpnState vpn = VpnState.running,
      bool otherVpn = false,
      bool privateDns = false,
      AccessibilityStatus a11y = AccessibilityStatus.disabled,
      int apps = 0,
      bool? battery = true,
      AlertsState? alerts = const AlertsState(permission: true),
    }) => SetupFacts(
      supported: true,
      vpnPermission: permission,
      snapshot: EngineSnapshot(
        vpnState: vpn,
        otherVpnActive: otherVpn,
        privateDnsStrict: privateDns,
      ),
      protectionEnabled: true,
      accessibility: a11y,
      protectedAppCount: apps,
      batteryOptimizationIgnored: battery,
      alerts: alerts,
    );

    CheckStatus status(List<SetupCheck> c, SetupCheckId id) =>
        c.firstWhere((x) => x.id == id).status;

    test('healthy device: required items ok, nothing unobservable is ok', () {
      final c = evaluateSetup(facts());
      expect(status(c, SetupCheckId.vpnConsent), CheckStatus.ok);
      expect(status(c, SetupCheckId.protectionRunning), CheckStatus.ok);
      expect(status(c, SetupCheckId.accessibility), CheckStatus.notNeeded);
      expect(status(c, SetupCheckId.notifications), CheckStatus.ok);
      // Always-on VPN can't be read by apps: never claimed as done.
      expect(status(c, SetupCheckId.alwaysOn), CheckStatus.recommended);
    });

    test('notifications: only for the optional alert', () {
      final missing = evaluateSetup(
        facts(alerts: const AlertsState(permission: false)),
      ).firstWhere((x) => x.id == SetupCheckId.notifications);
      expect(missing.status, CheckStatus.recommended);
      expect(missing.action, CheckAction.requestNotifications);
      expect(
        status(
          evaluateSetup(facts(alerts: const AlertsState(enabled: false))),
          SetupCheckId.notifications,
        ),
        CheckStatus.notNeeded,
      );
      expect(
        status(evaluateSetup(facts(alerts: null)), SetupCheckId.notifications),
        CheckStatus.unknown,
      );
    });

    test('missing consent and stopped VPN each get an action', () {
      final c = evaluateSetup(facts(permission: false, vpn: VpnState.stopped));
      final consent = c.firstWhere((x) => x.id == SetupCheckId.vpnConsent);
      expect(consent.status, CheckStatus.missing);
      expect(consent.action, CheckAction.grantVpn);
      expect(
        c.firstWhere((x) => x.id == SetupCheckId.protectionRunning).action,
        CheckAction.startProtection,
      );
    });

    test('other VPN, Private DNS, accessibility and battery', () {
      final c = evaluateSetup(
        facts(
          vpn: VpnState.revoked,
          otherVpn: true,
          privateDns: true,
          apps: 2,
          battery: false,
        ),
      );
      expect(status(c, SetupCheckId.otherVpn), CheckStatus.missing);
      expect(status(c, SetupCheckId.privateDns), CheckStatus.missing);
      expect(status(c, SetupCheckId.accessibility), CheckStatus.missing);
      expect(status(c, SetupCheckId.battery), CheckStatus.recommended);
      expect(
        status(
          evaluateSetup(facts(apps: 1, a11y: AccessibilityStatus.unavailable)),
          SetupCheckId.accessibility,
        ),
        CheckStatus.unknown,
      );
      expect(
        status(evaluateSetup(facts(battery: null)), SetupCheckId.battery),
        CheckStatus.unknown,
      );
    });
  });

  group('diagnostic report privacy', () {
    DiagnosticReport build(Map<String, Object?> native) =>
        DiagnosticReport.build(
          native: native,
          appVersion: '1.6.0 (7)',
          flavor: 'prod',
          buildMode: 'release',
          language: 'ar',
        );

    test('only whitelisted keys; free text is redacted', () {
      final text = build({
        'model': 'Infinix X6528',
        'vpnState': 'running',
        'bundledLists': {'gambling': 342623, 'sexual': 953393},
        // None of these may ever reach the report:
        'recentDomain': 'adult-site.test',
        'lastQuery': 'how to hide from parents',
        'pin': '739154',
        'mode': 'https://evil.test/?q=secret',
        'lastBoot': 'مرحبا',
      }).toText();
      expect(text, contains('model: Infinix X6528'));
      expect(text, contains('bundledLists: gambling=342623, sexual=953393'));
      for (final leak in [
        'adult-site',
        'hide from parents',
        '739154',
        'evil.test',
        'secret',
        'مرحبا',
      ]) {
        expect(text, isNot(contains(leak)), reason: leak);
      }
      expect(text, contains('mode: [redacted]'));
    });

    test('values reduce to tokens', () {
      expect(DiagnosticReport.sanitize(true), 'yes');
      expect(DiagnosticReport.sanitize(3), '3');
      expect(DiagnosticReport.sanitize(null), '—');
      expect(DiagnosticReport.sanitize(['a']), '[redacted]');
    });

    test('app version matches pubspec', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec,
        contains('version: ${AppInfo.version}+${AppInfo.buildNumber}'),
      );
    });
  });

  group('wizard verdict', () {
    test('ACTIVE only when native health says protected', () {
      expect(wizardResultFor(OverallHealth.protected), WizardResult.active);
      expect(
        wizardResultFor(OverallHealth.partiallyProtected),
        WizardResult.partial,
      );
      expect(wizardResultFor(OverallHealth.notProtected), WizardResult.failed);
      expect(wizardResultFor(OverallHealth.unknown), WizardResult.failed);
    });
  });

  group('Phase 7 screens', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first
        ..physicalSize = const Size(1080, 2340)
        ..devicePixelRatio = 3;
    });

    Future<void> tapNext(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('first run wizard: 8 steps, consent, verified ACTIVE', (
      tester,
    ) async {
      final engine = FakeProtectionEngine();
      final deps = testDependencies(engine: engine);
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await openPinSetup(tester);
      await enterPin(tester, '739154');
      await enterPin(tester, '739154');

      expect(find.text('تفعيل حماية SafeGuard'), findsOneWidget);
      // 1: mode. Choosing NORMAL applies immediately (no second PIN on
      // first run: it was created seconds ago).
      await tester.tap(find.text('عادي'));
      await tester.pumpAndSettle();
      expect(deps.protection.state.mode, ProtectionMode.normal);
      for (var i = 0; i < 5; i++) {
        await tapNext(tester, 'التالي'); // categories … PIN
      }
      expect(find.text('تم الإنشاء'), findsOneWidget);
      await tapNext(tester, 'التالي'); // permissions
      expect(find.text('موافقة VPN'), findsOneWidget);
      await tester.tap(find.text('منح الموافقة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تفعيل الحماية').last); // our explainer
      await tester.pumpAndSettle();
      expect(engine.permissionRequests, 1);
      final start = find.text('تشغيل الحماية').last;
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(engine.current.vpnState, VpnState.running);

      await tapNext(tester, 'تحقق');
      expect(find.text('حماية SafeGuard:'), findsOneWidget);
      expect(find.text('نشطة'), findsWidgets);
      await tapNext(tester, 'إنهاء');
      expect(deps.settings.setupPending, isFalse);
      expect(find.text('الحماية نشطة'), findsOneWidget);
    });

    testWidgets('wizard shows FAILED when filtering is not running', (
      tester,
    ) async {
      final engine = FakeProtectionEngine()
        ..overall = OverallHealth.notProtected;
      final deps = testDependencies(engine: engine);
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await openPinSetup(tester);
      await enterPin(tester, '739154');
      await enterPin(tester, '739154');
      for (var i = 0; i < 6; i++) {
        await tapNext(tester, 'التالي');
      }
      await tapNext(tester, 'تحقق');
      expect(find.text('فشلت'), findsOneWidget);
      expect(find.text('فتح مساعد الإعداد'), findsOneWidget);
    });

    testWidgets('wizard from Settings asks for the PIN first', (tester) async {
      final deps = testDependencies(
        engine: FakeProtectionEngine(permissionGranted: true),
      );
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await openPinSetup(tester);
      await createPinAndSkipWizard(tester, '739154');
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('معالج تفعيل الحماية'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, '111222');
      await tester.tap(find.byTooltip('إلغاء'));
      await tester.pumpAndSettle();
      expect(find.text('تفعيل حماية SafeGuard'), findsNothing);
    });

    testWidgets('setup assistant explains and fixes missing items', (
      tester,
    ) async {
      final engine = FakeProtectionEngine()
        ..overall = OverallHealth.notProtected;
      final deps = testDependencies(engine: engine);
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await openPinSetup(tester);
      await createPinAndSkipWizard(tester, '739154');
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('مساعد الإعداد'));
      await tester.pumpAndSettle();
      expect(find.text('غير محمي'), findsOneWidget);
      expect(find.text('مطلوب'), findsWidgets);
      final battery = find.text('إعدادات البطارية');
      await tester.scrollUntilVisible(
        battery,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(battery);
      await tester.pumpAndSettle();
      await tester.tap(battery);
      await tester.pumpAndSettle();
      expect(engine.batterySettingsOpened, 1);
    });

    testWidgets('diagnostics copies a report without personal data', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      final engine = FakeProtectionEngine(permissionGranted: true);
      engine.rules.add(
        const DomainRule(domain: 'secret-site.test', action: RuleAction.block),
      );
      final deps = testDependencies(engine: engine);
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await openPinSetup(tester);
      await createPinAndSkipWizard(tester, '739154');
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      final entry = find.text('التشخيص');
      await tester.scrollUntilVisible(
        entry,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.tap(find.text('نسخ معلومات التشخيص'));
      await tester.pumpAndSettle();
      expect(copied, isNotNull);
      expect(copied, contains('model: X1'));
      expect(copied, isNot(contains('secret-site')));
      expect(copied, isNot(contains('739154')));
    });

    testWidgets('help, about and privacy open from Settings', (tester) async {
      final deps = testDependencies(
        engine: FakeProtectionEngine(permissionGranted: true),
      );
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await openPinSetup(tester);
      await createPinAndSkipWizard(tester, '739154');
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      for (final (entry, title) in [
        ('المساعدة', 'حل المشكلات'),
        ('الخصوصية وبياناتك', 'ما لا يُجمع أبدًا'),
        ('حول SafeGuard', 'المصادر والتراخيص'),
      ]) {
        final tile = find.text(entry);
        await tester.scrollUntilVisible(
          tile,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget, reason: entry);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
    });
  });
}
