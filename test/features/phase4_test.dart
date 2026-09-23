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

  group('Phase 4 platform channel contract', () {
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
            final settings = {
              'enabled': args['enabled'] ?? true,
              'mode': args['mode'] ?? 'strict',
              'custom': args['custom'] ?? {'sexual': 0.6, 'unknown_cat': 0.5},
              'profiles': {
                'normal': {'sexual': 0.9, 'gore': 0.85},
                'strict': {'sexual': 0.7, 'gore': 0.65},
              },
              'customRange': [0.5, 0.99],
              'models': {
                'text': {'id': 'sg-text-1', 'version': 1, 'available': true},
                'image': {'id': null, 'version': null, 'available': false},
              },
            };
            return switch (call.method) {
              'getAiSettings' || 'setAiSettings' => settings,
              'getAiStatistics' => {
                'detections': 5,
                'blocks': 3,
                'falsePositiveReports': 1,
                'detectionsByCategory': {'sexual': 4, 'safe': 9},
                'blocksByCategory': {'sexual': 3},
                'reportsByCategory': {'sexual': 1},
              },
              'reportFalsePositive' => true,
              'checkImage' => {
                'status': 'unavailable',
                'error': 'no_model',
                'action': 'unknown',
                'category': 'unknown',
                'confidence': 0.0,
                'reason': 'ai_unavailable',
                'scores': <String, Object>{},
                'modelId': null,
              },
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, null);
    });

    test('AI settings: parsing, profiles from native, models', () async {
      final s = await engine.aiSettings();
      expect(s.mode, DetectionMode.strict);
      expect(s.threshold(ProtectionCategory.sexual), 0.7);
      expect(s.threshold(ProtectionCategory.gore), 0.65);
      // Categories missing from native profiles fall back to defaults.
      expect(s.threshold(ProtectionCategory.drugs), 0.70);
      expect(s.custom, {ProtectionCategory.sexual: 0.6});
      expect(s.textModelAvailable, isTrue);
      expect(s.textModelId, 'sg-text-1');
      expect(s.imageModelAvailable, isFalse);
    });

    test('setAiSettings sends only enabled, mode and custom', () async {
      await engine.setAiSettings(
        const AiSettings(
          mode: DetectionMode.custom,
          custom: {ProtectionCategory.gore: 0.8},
        ),
      );
      final call = calls.single;
      expect(call.method, 'setAiSettings');
      expect(call.arguments, {
        'enabled': true,
        'mode': 'custom',
        'custom': {'gore': 0.8},
      });
    });

    test('statistics parse; unknown categories ignored', () async {
      final s = await engine.aiStatistics();
      expect(s.detections, 5);
      expect(s.blocks, 3);
      expect(s.falsePositiveReports, 1);
      expect(s.detectionsByCategory, {ProtectionCategory.sexual: 4});
    });

    test('false-positive report carries no content', () async {
      await engine.reportFalsePositive(
        source: EventSourceKind.ai,
        category: ProtectionCategory.sexual,
        confidence: 0.91,
      );
      expect(calls.single.method, 'reportFalsePositive');
      expect(calls.single.arguments, {
        'source': 'ai',
        'category': 'sexual',
        'confidence': 0.91,
      });
    });

    test('image check without a model is reported honestly', () async {
      final r = await engine.checkImage();
      expect(r.status, ImageCheckStatus.unavailable);
      expect(r.error, 'no_model');
      expect(r.verdict, ContentVerdict.unknown);
      expect(r.category, isNull);
    });

    test('platform errors become typed failures', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            method,
            (call) async => throw PlatformException(code: 'INVALID_ARGUMENT'),
          );
      expect(
        engine.setAiSettings(const AiSettings()),
        throwsA(isA<EngineFailure>()),
      );
    });
  });

  group('AiSettings', () {
    test('defaults: normal mode, thresholds from the spec', () {
      const s = AiSettings();
      expect(s.enabled, isTrue);
      expect(s.threshold(ProtectionCategory.sexual), 0.90);
      expect(s.threshold(ProtectionCategory.gore), 0.85);
    });

    test('custom thresholds are clamped and fall back to normal', () {
      const s = AiSettings(
        mode: DetectionMode.custom,
        custom: {ProtectionCategory.sexual: 0.1, ProtectionCategory.drugs: 1.5},
      );
      expect(s.threshold(ProtectionCategory.sexual), 0.5);
      expect(s.threshold(ProtectionCategory.drugs), 0.99);
      expect(s.threshold(ProtectionCategory.violence), 0.90);
    });

    test('loosening needs the PIN; tightening does not', () {
      const normal = AiSettings();
      const strict = AiSettings(mode: DetectionMode.strict);
      expect(normal.isLoosenedBy(normal.copyWith(enabled: false)), isTrue);
      expect(normal.isLoosenedBy(strict), isFalse);
      expect(strict.isLoosenedBy(normal), isTrue);
      expect(
        normal.isLoosenedBy(
          const AiSettings(
            mode: DetectionMode.custom,
            custom: {ProtectionCategory.gambling: 0.95},
          ),
        ),
        isTrue,
      );
      expect(
        normal.isLoosenedBy(
          const AiSettings(
            mode: DetectionMode.custom,
            custom: {ProtectionCategory.gambling: 0.6},
          ),
        ),
        isFalse,
      );
      expect(normal.copyWith(enabled: false).isLoosenedBy(normal), isFalse);
    });

    test('malformed native maps fall back to protective defaults', () {
      final s = AiSettings.fromMap({'enabled': 'yes', 'mode': 'weird'});
      expect(s.enabled, isTrue);
      expect(s.mode, DetectionMode.normal);
      expect(s.textModelAvailable, isFalse);
    });
  });

  group('ProtectionController ↔ AI', () {
    test('settings and statistics sync with the engine', () async {
      final engine = FakeProtectionEngine(permissionGranted: true);
      final controller = ProtectionController(
        repository: LocalProtectionRepository(MemoryStore()),
        engine: engine,
      );
      await controller.load();
      expect(controller.aiSettings.textModelId, 'sg-text-1');
      final r = await controller.setAiSettings(
        controller.aiSettings.copyWith(mode: DetectionMode.strict),
      );
      expect(r.isOk, isTrue);
      expect(engine.ai.mode, DetectionMode.strict);
      await controller.reportFalsePositive(
        source: EventSourceKind.ai,
        category: ProtectionCategory.gore,
        confidence: 0.9,
      );
      await controller.refreshAi();
      expect(engine.reports.single.$2, ProtectionCategory.gore);
      expect(controller.aiStatistics.falsePositiveReports, 1);
      controller.dispose();
    });
  });

  group('Phase 4 screens', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first
        ..physicalSize = const Size(1080, 2340)
        ..devicePixelRatio = 3;
    });

    Future<FakeProtectionEngine> open(
      WidgetTester tester,
      String entry, {
      FakeProtectionEngine? engine,
    }) async {
      final e = engine ?? FakeProtectionEngine(permissionGranted: true);
      final prefs = MemoryStore();
      final secure = MemoryStore();
      final seed = testDependencies(prefs: prefs, secure: secure, engine: e);
      await seed.initialize();
      await seed.security.createPin('739154', '739154');
      await seed.settings.completeOnboarding();
      await seed.settings.setAppLock(false);
      await tester.pumpWidget(
        SafeGuardApp(
          dependencies: testDependencies(
            prefs: prefs,
            secure: secure,
            engine: e,
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
      return e;
    }

    Future<void> search(WidgetTester tester, String text) async {
      final box = find.byType(TextField);
      await tester.scrollUntilVisible(
        box,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(box, text);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'AI blocks an unseen search; the block can be reported as incorrect',
      (tester) async {
        final engine = await open(tester, 'حماية البحث');
        await search(tester, 'street brawl clips');

        expect(find.text('تم حظر هذا المحتوى'), findsOneWidget);
        final e = engine.logs.first;
        expect(e.source, EventSourceKind.ai);
        expect(e.ruleType, 'ai_text');
        expect(e.domain, isNot(contains('brawl')));

        await tester.tap(find.text('إبلاغ عن حظر خاطئ'));
        await tester.pumpAndSettle();
        expect(find.textContaining('لا يُحفظ المحتوى نفسه'), findsOneWidget);
        await tester.tap(find.text('إبلاغ'));
        await tester.pumpAndSettle();
        expect(engine.reports, [
          (EventSourceKind.ai, ProtectionCategory.violence, 0.95),
        ]);
        expect(find.text('تم الإبلاغ. شكرًا لك.'), findsOneWidget);
      },
    );

    testWidgets('rule-blocked search can be reported too', (tester) async {
      final engine = await open(tester, 'حماية البحث');
      await search(tester, 'online casino');
      await tester.tap(find.text('إبلاغ عن حظر خاطئ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(engine.reports, isEmpty);
    });

    testWidgets('AI off: unseen phrases are not classified', (tester) async {
      final engine = FakeProtectionEngine(permissionGranted: true)
        ..ai = const AiSettings(enabled: false);
      await open(tester, 'حماية البحث', engine: engine);
      await search(tester, 'street brawl clips');
      expect(find.text('تم حظر هذا المحتوى'), findsNothing);
    });

    testWidgets('normal vs strict: a 0.80 score blocks only in strict', (
      tester,
    ) async {
      final engine = await open(tester, 'حماية البحث');
      await search(tester, 'risque photos');
      expect(find.text('تم حظر هذا المحتوى'), findsNothing);
      engine.ai = const AiSettings(mode: DetectionMode.strict);
      await search(tester, 'risque photos');
      expect(find.text('تم حظر هذا المحتوى'), findsOneWidget);
    });

    testWidgets('disabling AI needs the PIN and can be cancelled', (
      tester,
    ) async {
      final engine = await open(tester, 'الحماية الذكية');
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await tester.tap(find.byTooltip('إلغاء'));
      await tester.pumpAndSettle();
      expect(engine.ai.enabled, isTrue);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await enterPin(tester, '739154');
      expect(engine.ai.enabled, isFalse);

      // Turning it back on is tightening: no PIN.
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsNothing);
      expect(engine.ai.enabled, isTrue);
    });

    testWidgets('strict needs no PIN; back to normal needs it', (tester) async {
      final engine = await open(tester, 'الحماية الذكية');
      await tester.tap(find.text('صارم'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsNothing);
      expect(engine.ai.mode, DetectionMode.strict);

      await tester.tap(find.text('عادي'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsOneWidget);
      await enterPin(tester, '739154');
      expect(engine.ai.mode, DetectionMode.normal);
    });

    testWidgets('custom mode exposes the threshold editor', (tester) async {
      final engine = await open(tester, 'الحماية الذكية');
      await tester.tap(find.text('مخصص'));
      await tester.pumpAndSettle();
      // NORMAL → CUSTOM with no values changes no threshold: no PIN.
      expect(find.text('أدخل رمز PIN'), findsNothing);
      expect(engine.ai.mode, DetectionMode.custom);
      await tester.scrollUntilVisible(
        find.text('تعديل الحدود'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('تعديل الحدود'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تعديل الحدود'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNWidgets(6));
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل رمز PIN'), findsNothing);
      expect(engine.ai.threshold(ProtectionCategory.gore), 0.85);
    });

    testWidgets('image check without a model says so; nothing is invented', (
      tester,
    ) async {
      final engine = await open(tester, 'الحماية الذكية');
      await tester.scrollUntilVisible(
        find.text('اختيار صورة'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('لا يوجد نموذج صور مثبّت'), findsOneWidget);
      await tester.ensureVisible(find.text('اختيار صورة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اختيار صورة'));
      await tester.pumpAndSettle();
      expect(engine.imageChecks, 1);
      expect(find.text('التصنيف غير متاح'), findsOneWidget);
      expect(find.text('إبلاغ عن حظر خاطئ'), findsNothing);
    });

    testWidgets('rejected and blocked image results render', (tester) async {
      final engine = FakeProtectionEngine(permissionGranted: true)
        ..imageResult = const ImageCheck(
          status: ImageCheckStatus.rejected,
          error: 'unsupported_type',
        );
      await open(tester, 'الحماية الذكية', engine: engine);
      final pick = find.text('اختيار صورة');
      await tester.scrollUntilVisible(
        pick,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(pick);
      await tester.pumpAndSettle();
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(find.textContaining('JPEG'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // dismiss sheet
      await tester.pumpAndSettle();

      engine.imageResult = const ImageCheck(
        status: ImageCheckStatus.ok,
        verdict: ContentVerdict.block,
        category: ProtectionCategory.sexual,
        confidence: 0.97,
        scores: {ProtectionCategory.sexual: 0.97},
        modelId: 'img',
      );
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(find.text('سيُحظر هذا المحتوى'), findsOneWidget);
      expect(find.text('97٪'), findsWidgets);
      await tester.tap(find.text('إبلاغ عن حظر خاطئ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إبلاغ'));
      await tester.pumpAndSettle();
      expect(engine.reports.single.$2, ProtectionCategory.sexual);
    });

    testWidgets('statistics show counts only', (tester) async {
      final engine = FakeProtectionEngine(permissionGranted: true)
        ..aiStats = const AiStatistics(
          detections: 7,
          blocks: 4,
          falsePositiveReports: 2,
          detectionsByCategory: {ProtectionCategory.gambling: 7},
          blocksByCategory: {ProtectionCategory.gambling: 4},
        );
      await open(tester, 'الحماية الذكية', engine: engine);
      await tester.scrollUntilVisible(
        find.text('بلاغات حظر خاطئ'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('7'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('7 اكتشاف · 4 حظر'), findsOneWidget);
    });
  });
}
