import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/app/safeguard_app.dart';
import 'package:safeguard/core/entitlements/plan.dart';
import 'package:safeguard/core/error/app_logger.dart';
import 'package:safeguard/core/observability/crash_reporter.dart';
import 'package:safeguard/core/observability/telemetry.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/diagnostics/domain/diagnostic_report.dart';
import 'package:safeguard/features/feedback/domain/feedback.dart';
import 'package:safeguard/features/protection/domain/protection.dart';

import '../app/app_flow_test.dart'
    show createPinAndSkipWizard, enterPin, openPinSetup, testDependencies;
import '../support/fake_protection_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decision explanations', () {
    test('Dart codes match native Explanation (id and verdict)', () {
      final kotlin = File(
        'android/app/src/main/kotlin/com/safeguard/app/engine/explain/DecisionExplanation.kt',
      ).readAsStringSync();
      final native = {
        for (final m in RegExp(
          r'\("([a-z_]+)", Verdict\.(BLOCKED|ALLOWED)\)',
        ).allMatches(kotlin))
          m.group(1)!: m.group(2) == 'BLOCKED',
      };
      expect(native, isNotEmpty);
      expect({
        for (final e in DecisionExplanation.values) e.id: e.blocks,
      }, native);
    });

    test('every explanation has text in both languages', () {
      for (final e in DecisionExplanation.values) {
        expect(e.reason, isNotEmpty);
      }
    });

    test('trace parsing keeps only known, content-free fields', () {
      final t = DecisionTraceSnapshot.fromMap({
        'enabled': true,
        'entries': [
          {
            'timestamp': 1000,
            'source': 'dns',
            'explanation': 'known_blocked_domain',
            'category': 'gambling',
            'stages': ['protection', 'allowlist', 'lists'],
            'domain': 'must-not-appear.test',
          },
          {'timestamp': 1, 'explanation': 'made_up'},
        ],
      });
      expect(t.entries, hasLength(1));
      expect(t.entries.single.stages.last, 'lists');
    });
  });

  group('crash reporter', () {
    test('keeps error type and app frames, never the message', () async {
      final r = LocalCrashReporter(
        MemoryStore(),
        appVersion: '1.7.0',
        androidVersion: '13',
        deviceModel: 'X1',
      );
      await r.load();
      final stack = StackTrace.fromString(
        '#0      SearchScreen._submit (package:safeguard/features/search/x.dart:42:7)\n'
        '#1      _rootRun (dart:async/zone.dart:1399:13)\n'
        '#2      Foo.bar (package:other_pkg/y.dart:3:1)',
      );
      await r.record(
        StateError('failed for https://secret.test/?q=private&token=abc'),
        stack,
      );
      final list = await r.reports();
      expect(list, hasLength(1));
      final text = list.single.toText();
      expect(list.single.errorType, 'StateError');
      expect(list.single.frames, [
        'SearchScreen._submit (features/search/x.dart:42)',
      ]);
      for (final leak in ['secret.test', 'private', 'token', 'zone.dart']) {
        expect(text, isNot(contains(leak)), reason: leak);
      }
      expect(text, contains('Android 13'));
    });

    test('can be turned off; off deletes and stops recording', () async {
      final store = MemoryStore();
      final r = LocalCrashReporter(store, appVersion: '1');
      await r.record(Exception('x'), null);
      await r.setEnabled(false);
      await r.record(Exception('y'), null);
      expect(await r.reports(), isEmpty);
      final reloaded = LocalCrashReporter(store, appVersion: '1');
      await reloaded.load();
      expect(reloaded.enabled, isFalse);
    });

    test('keeps at most 10 reports', () async {
      final r = LocalCrashReporter(MemoryStore(), appVersion: '1');
      for (var i = 0; i < 15; i++) {
        await r.record(Exception('$i'), null);
      }
      expect(await r.reports(), hasLength(10));
    });
  });

  group('telemetry', () {
    test('off by default: nothing is counted', () async {
      final t = LocalTelemetry(MemoryStore());
      await t.load();
      expect(t.enabled, isFalse);
      await t.count(TelemetryEvent.crash);
      expect((await t.report()).isEmpty, isTrue);
    });

    test('opt-in counts per day; opting out deletes', () async {
      final store = MemoryStore();
      final t = LocalTelemetry(store, clock: () => DateTime(2026, 10, 1));
      await t.setEnabled(true);
      await t.count(TelemetryEvent.engineFailure);
      await t.count(TelemetryEvent.engineFailure);
      final r = await t.report();
      expect(r.total(TelemetryEvent.engineFailure), 2);
      expect(r.days.keys, ['2026-10-01']);
      // Stored data has no identifiers of any kind.
      expect(store.values.values.join(), isNot(contains('device')));
      await t.setEnabled(false);
      expect((await t.report()).isEmpty, isTrue);
    });

    test('app errors are routed only when observed', () async {
      final deps = testDependencies();
      await deps.initialize();
      await deps.telemetry.setEnabled(true);
      deps.observeErrors();
      AppLogger.error('uncaught', StateError('boom'), StackTrace.current);
      AppLogger.error('engine', Exception('x'));
      await pumpEventQueue();
      final r = await deps.telemetry.report();
      expect(r.total(TelemetryEvent.crash), 1);
      expect(r.total(TelemetryEvent.engineFailure), 1);
      expect(await deps.crashes.reports(), hasLength(1));
      AppLogger.onError = null;
    });
  });

  group('feedback', () {
    test('shares only what the user chose', () {
      const draft = FeedbackDraft(
        type: FeedbackType.falsePositive,
        category: ProtectionCategory.gambling,
        source: EventSourceKind.dns,
      );
      final text = draft.toText(appVersion: '1.7.0 (8)', flavor: 'prod');
      expect(text, contains('type: false_positive'));
      expect(text, contains('category: gambling'));
      expect(text, isNot(contains('description')));
      expect(text, isNot(contains('SafeGuard diagnostics')));

      final report = DiagnosticReport.build(
        native: {'model': 'X1'},
        appVersion: '1',
        flavor: 'prod',
        buildMode: 'release',
        language: 'ar',
      );
      final withDiag = draft
          .copyWith(includeDiagnostics: true, description: 'x' * 600)
          .toText(appVersion: '1', flavor: 'prod', diagnostics: report);
      expect(withDiag, contains('SafeGuard diagnostics'));
      expect(withDiag, contains('x' * FeedbackDraft.maxDescription));
      expect(
        withDiag,
        isNot(contains('x' * (FeedbackDraft.maxDescription + 1))),
      );
    });

    test('warns about links, emails and long numbers', () {
      expect(sensitiveHints('it was https://a.test'), ['link']);
      expect(sensitiveHints('mail me a@b.co'), ['email']);
      expect(sensitiveHints('call 0791234567'), ['number']);
      expect(sensitiveHints('the page stayed blocked'), isEmpty);
    });
  });

  group('entitlements', () {
    test('protection never depends on a plan', () async {
      expect(await const FreeEntitlements().currentPlan(), Plan.free);
      for (final f in ProtectionFeature.values) {
        for (final p in Plan.values) {
          expect(Entitlements.protectionAvailable(f, p), isTrue);
        }
      }
    });

    test('the protection engine does not import billing code', () {
      final offenders = Directory('lib/features/protection')
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (f) => f.readAsStringSync().contains('entitlements/plan.dart'),
          );
      expect(offenders, isEmpty);
    });
  });

  group('Phase 8 screens', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first
        ..physicalSize = const Size(1080, 2340)
        ..devicePixelRatio = 3;
    });

    Future<FakeProtectionEngine> launch(WidgetTester tester) async {
      final engine = FakeProtectionEngine(permissionGranted: true);
      final deps = testDependencies(engine: engine);
      await tester.pumpWidget(SafeGuardApp(dependencies: deps));
      await tester.pumpAndSettle();
      await openPinSetup(tester);
      await createPinAndSkipWizard(tester, '739154');
      await tester.tap(find.text('الإعدادات').last);
      await tester.pumpAndSettle();
      return engine;
    }

    Future<void> openEntry(WidgetTester tester, String entry) async {
      final f = find.text(entry);
      await tester.scrollUntilVisible(
        f,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('feedback: preview shows exactly what is copied', (
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
      await launch(tester);
      await openEntry(tester, 'إرسال ملاحظات');
      await tester.tap(find.text('محتوى لم يُحجب'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Gambling ads appeared');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('feedback-preview')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final preview = tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('feedback-preview')),
          )
          .data!;
      expect(preview, contains('type: missed_content'));
      expect(preview, isNot(contains('SafeGuard diagnostics')));
      final copy = find.text('نسخ التقرير');
      await tester.ensureVisible(copy);
      await tester.pumpAndSettle();
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, preview);
    });

    testWidgets('analytics is off by default and can be enabled', (
      tester,
    ) async {
      await launch(tester);
      await openEntry(tester, 'التحليلات والتقارير');
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches.first.value, isFalse); // analytics
      expect(switches[1].value, isTrue); // local crash reports
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<Switch>(find.byType(Switch)).first.value,
        isTrue,
      );
    });

    testWidgets('turning protection alerts off needs the PIN', (tester) async {
      final engine = await launch(tester);
      final tile = find.text('تنبيه عند توقف الحماية');
      await tester.scrollUntilVisible(
        tile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      final sw = find.descendant(
        of: find.ancestor(of: tile, matching: find.byType(Row)).first,
        matching: find.byType(Switch),
      );
      await tester.tap(sw.evaluate().isEmpty ? tile : sw);
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, '739154');
      expect(engine.alerts.enabled, isFalse);
    });

    testWidgets('diagnostics decision trace toggles', (tester) async {
      final engine = await launch(tester);
      await openEntry(tester, 'التشخيص');
      final tile = find.text('تسجيل آخر 50 قرارًا');
      await tester.scrollUntilVisible(
        tile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(engine.trace.enabled, isTrue);
    });
  });
}
