import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:safeguard/app/router/routes.dart';
import 'package:safeguard/app/safeguard_app.dart';
import 'package:safeguard/features/protection/domain/protection.dart';

import '../app/app_flow_test.dart'
    show createPinAndSkipWizard, enterPin, openPinSetup, testDependencies;
import '../support/fake_protection_engine.dart';

const _kotlin = 'android/app/src/main/kotlin/com/safeguard/app/engine/shield';

/// Ids of a Kotlin enum declared as `NAME("id")` inside `enum class [name]`.
Set<String> _kotlinIds(String file, String name) {
  final src = File('$_kotlin/$file').readAsStringSync();
  final start = src.indexOf('enum class $name(');
  expect(start, isNot(-1), reason: '$name not found in $file');
  final block = src.substring(start, src.indexOf('\n}', start));
  return {
    for (final m in RegExp(r'\n\s+[A-Z_]+\("([a-z_]+)"').allMatches(block))
      m.group(1)!,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dart ↔ Kotlin shield contract', () {
    test('state, issue, model-state, level and limitation ids match', () {
      expect({
        for (final s in ShieldState.values) s.id,
      }, _kotlinIds('ContentShield.kt', 'ShieldState'));
      expect({
        for (final s in ShieldIssue.values) s.id,
      }, _kotlinIds('ContentShield.kt', 'ShieldIssue'));
      expect({
        for (final s in ImageModelState.values) s.id,
      }, _kotlinIds('ImageModelPack.kt', 'ImageModelState'));
      expect({
        for (final s in ShieldSupportLevel.values) s.id,
      }, _kotlinIds('SupportedApps.kt', 'SupportLevel'));
      expect({
        for (final s in ShieldLimitation.values) s.id,
      }, _kotlinIds('SupportedApps.kt', 'ShieldLimitation'));
    });

    test('parsing keeps known values and fails closed', () {
      final s = ShieldStatus.fromMap({
        'enabled': true,
        'state': 'partial',
        'issues': ['image_model_unavailable', 'made_up'],
        'textActive': true,
        'imageActive': false,
        'accessibility': 'enabled',
        'textModel': 'sg-text-1',
        'textModelAvailable': true,
        'imageModelState': 'not_bundled',
        'apps': [
          {
            'key': 'chrome',
            'name': 'Chrome',
            'packages': ['com.android.chrome'],
            'level': 'text',
            'limitations': ['images_need_capture', 'bogus'],
            'enabled': true,
            'installed': true,
            'verifiedOnDevice': false,
          },
          {'name': 'no key'},
        ],
      });
      expect(s.state, ShieldState.partial);
      expect(s.issues, [ShieldIssue.imageModelUnavailable]);
      expect(s.apps.single.limitations, [ShieldLimitation.imagesNeedCapture]);
      expect(s.imageModelState.usable, isFalse);
      // Unknown or missing state never reads as "active".
      expect(ShieldStatus.fromMap({}).state, ShieldState.unavailable);
      expect(ShieldStatus.fromMap({'state': 'bogus'}).isChecking, isFalse);
    });

    test('every issue and limitation has text in both languages', () {
      for (final i in ShieldIssue.values) {
        expect(i.message, isNotEmpty);
      }
      for (final l in ShieldLimitation.values) {
        expect(l.message, isNotEmpty);
      }
    });

    test('shield block events explain themselves', () {
      expect(
        DecisionExplanation.fromId('ai_content_shield'),
        DecisionExplanation.aiContentShield,
      );
      expect(DecisionExplanation.aiContentShield.blocks, isTrue);
    });
  });

  group('AI Content Shield screen', () {
    Future<FakeProtectionEngine> open(
      WidgetTester tester, {
      void Function(FakeProtectionEngine)? setup,
    }) async {
      final engine = FakeProtectionEngine(permissionGranted: true);
      setup?.call(engine);
      await tester.pumpWidget(
        SafeGuardApp(dependencies: testDependencies(engine: engine)),
      );
      await tester.pumpAndSettle();
      await openPinSetup(tester);
      await createPinAndSkipWizard(tester, '739154');
      unawaited(
        GoRouter.of(tester.element(find.byType(Scaffold).first))
            .push(Routes.contentShield),
      );
      await tester.pumpAndSettle();
      return engine;
    }

    Finder switchOf(String title) => find.descendant(
      of: find
          .ancestor(of: find.text(title).last, matching: find.byType(Row))
          .first,
      matching: find.byType(Switch),
    );

    testWidgets('is off by default and never claims image checks', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('درع المحتوى الذكي'), findsWidgets);
      expect(find.text('متوقف'), findsWidgets);
      // Both capabilities read "not running" while off.
      expect(find.text('لا يعمل'), findsNWidgets(2));
      expect(find.text('يعمل'), findsNothing);
    });

    testWidgets('turning it on asks for consent before Android settings', (
      tester,
    ) async {
      final engine = await open(tester);
      await tester.tap(switchOf('درع المحتوى الذكي'));
      await tester.pumpAndSettle();
      expect(engine.shieldEnabled, isTrue);
      expect(find.text('موافق، افتح الإعدادات'), findsOneWidget);
      await tester.ensureVisible(find.text('لا أوافق'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('لا أوافق'));
      await tester.pumpAndSettle();
      expect(engine.shieldDisclosureAnswers, [false]);
      // Still unavailable: the service isn't on, so nothing is checked.
      expect(find.text('غير متاح'), findsWidgets);
    });

    testWidgets('with the service on it is only partially active', (
      tester,
    ) async {
      final engine = await open(tester);
      engine.shieldAccessibility = AccessibilityStatus.enabled;
      await tester.tap(switchOf('درع المحتوى الذكي'));
      await tester.pumpAndSettle();
      expect(find.text('يعمل جزئيًا'), findsOneWidget);
      expect(find.text('يعمل'), findsOneWidget); // text checks only
      expect(find.textContaining('فحص الصور متوقف'), findsWidgets);
    });

    testWidgets('turning the shield or an app off needs the PIN', (
      tester,
    ) async {
      final engine = await open(
        tester,
        setup: (e) => e
          ..shieldEnabled = true
          ..shieldAccessibility = AccessibilityStatus.enabled,
      );

      final reddit = find.text('Reddit');
      await tester.scrollUntilVisible(
        reddit,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(switchOf('Reddit'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, '739154');
      expect(engine.shieldDisabledApps, {'reddit'});

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await tester.pumpAndSettle();
      await tester.tap(switchOf('درع المحتوى الذكي'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, '739154');
      expect(engine.shieldEnabled, isFalse);
    });

    testWidgets('image checks need consent to start and the PIN to stop', (
      tester,
    ) async {
      final engine = await open(
        tester,
        setup: (e) => e
          ..shieldEnabled = true
          ..shieldAccessibility = AccessibilityStatus.enabled,
      );
      final start = find.text('تفعيل فحص الصور');
      await tester.scrollUntilVisible(
        start,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();
      // SafeGuard's explanation first, then Android's own dialog.
      await tester.ensureVisible(find.text('متابعة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();
      expect(engine.screenCaptureRequests, 1);
      expect(engine.screenCapture, isTrue);
      // Text and image both running: the only time the shield reads "active".
      expect(find.text('يعمل'), findsWidgets);

      final stop = find.text('إيقاف فحص الصور');
      await tester.ensureVisible(stop);
      await tester.pumpAndSettle();
      await tester.tap(stop);
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, '739154');
      expect(engine.screenCapture, isFalse);
    });

    testWidgets('declining Android capture keeps image checks off', (
      tester,
    ) async {
      final engine = await open(
        tester,
        setup: (e) => e
          ..shieldEnabled = true
          ..shieldAccessibility = AccessibilityStatus.enabled
          ..grantScreenCapture = false,
      );
      final start = find.text('تفعيل فحص الصور');
      await tester.scrollUntilVisible(
        start,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('متابعة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();
      expect(engine.screenCapture, isFalse);
      expect(find.text('تفعيل فحص الصور'), findsOneWidget);
    });
  });
}
