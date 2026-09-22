import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/app/router/app_router.dart';
import 'package:safeguard/app/safeguard_app.dart';

import 'package:safeguard/features/protection/domain/protection.dart';

import '../support/fake_protection_engine.dart';
import 'app_flow_test.dart' show testDependencies;

/// Renders every screen at small, common, tablet and landscape sizes, with
/// default and enlarged text, and fails on any layout overflow.
void main() {
  const sizes = {
    'small 320x568': Size(320, 568),
    'phone 360x640': Size(360, 640),
    'tall 412x915': Size(412, 915),
    'tablet 800x1280': Size(800, 1280),
    'landscape 780x360': Size(780, 360),
  };
  const screens = [
    '/welcome',
    '/pin/create',
    '/home',
    '/status',
    '/settings',
    '/blocked?category=gambling',
    '/change-pin',
    '/verify',
    '/rules/blocked',
    '/rules/allowed',
    '/activity',
  ];

  for (final textScale in [1.0, 1.3]) {
    for (final entry in sizes.entries) {
      testWidgets('no overflow: ${entry.key} @${textScale}x', (tester) async {
        tester.view.physicalSize = entry.value * 2;
        tester.view.devicePixelRatio = 2;
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final failures = <String>[];
        for (final screen in screens) {
          final engine = FakeProtectionEngine(permissionGranted: true);
          engine.rules.add(
            const DomainRule(
              domain: 'a-rather-long-subdomain.example-casino-site.test',
              action: RuleAction.block,
              category: ProtectionCategory.gambling,
            ),
          );
          engine.logs.addAll([
            for (final c in ProtectionCategory.networkFiltered)
              BlockEvent(
                time: DateTime(2026, 9, 22, 20, 41),
                domain: 'blocked-${c.id}.example.test',
                category: c,
              ),
          ]);
          final deps = testDependencies(engine: engine);
          await deps.initialize();
          if (screen != '/welcome' && screen != '/pin/create') {
            await deps.security.createPin('739154', '739154');
            await deps.settings.completeOnboarding();
          }
          final router = createRouter(deps);
          await tester.pumpWidget(
            SafeGuardApp(key: UniqueKey(), dependencies: deps, router: router),
          );
          await tester.pumpAndSettle();
          if (screen == '/verify') {
            unawaited(
              router.push(screen, extra: 'لإيقاف الحماية على هذا الجهاز'),
            );
          } else {
            router.go(screen);
          }
          await tester.pumpAndSettle();
          final error = tester.takeException();
          if (error != null) failures.add('$screen: $error');
        }
        expect(failures, isEmpty);
      });
    }
  }
}
