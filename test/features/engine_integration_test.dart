import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/core/error/failures.dart';
import 'package:safeguard/core/error/result.dart';
import 'package:safeguard/core/platform/protection_channel.dart';
import 'package:safeguard/core/storage/stores.dart';
import 'package:safeguard/features/protection/data/local_protection_repository.dart';
import 'package:safeguard/features/protection/data/native_protection_engine.dart';
import 'package:safeguard/features/protection/domain/protection.dart';
import 'package:safeguard/features/protection/presentation/protection_controller.dart';
import 'package:safeguard/features/rules/domain/domain_input.dart';

import '../support/fake_protection_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProtectionController + engine', () {
    Future<(ProtectionController, FakeProtectionEngine)> make({
      bool permission = true,
      ProtectionState? saved,
      EngineSnapshot? initial,
    }) async {
      final store = MemoryStore();
      if (saved != null) store.values['protection.v1'] = saved.encode();
      final engine = FakeProtectionEngine(permissionGranted: permission);
      if (initial != null) engine.emit(initial);
      final c = ProtectionController(
        repository: LocalProtectionRepository(store),
        engine: engine,
      );
      await c.load();
      return (c, engine);
    }

    test('resumes a stopped VPN on load when consent exists', () async {
      final (c, engine) = await make();
      expect(engine.current.vpnState, VpnState.running);
      await Future<void>.delayed(Duration.zero);
      expect(c.health, ProtectionHealth.active);
    });

    test('does not start without consent: inactive, needs attention', () async {
      final (c, engine) = await make(permission: false);
      expect(engine.current.vpnState, VpnState.stopped);
      expect(c.health, ProtectionHealth.inactive);
    });

    test('never auto-starts over another VPN', () async {
      final (c, engine) = await make(
        initial: const EngineSnapshot(
          vpnState: VpnState.stopped,
          otherVpnActive: true,
        ),
      );
      expect(engine.current.vpnState, VpnState.stopped);
      expect(c.health, ProtectionHealth.inactive);
    });

    test('does not resume when the user turned protection off', () async {
      final (c, engine) = await make(
        saved: ProtectionState.initial().copyWith(enabled: false),
      );
      expect(engine.current.vpnState, VpnState.stopped);
      expect(c.health, ProtectionHealth.paused);
    });

    test('turning off stops the VPN; turning on starts it', () async {
      final (c, engine) = await make();
      await c.setEnabled(false);
      await Future<void>.delayed(Duration.zero);
      expect(engine.current.vpnState, VpnState.stopped);
      expect(c.health, ProtectionHealth.paused);
      expect(engine.applied!.enabled, isFalse);

      await c.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(engine.current.vpnState, VpnState.running);
      expect(c.health, ProtectionHealth.active);
    });

    test('start without consent returns a typed failure', () async {
      final (c, _) = await make(permission: false);
      final r = await c.startEngine();
      expect(r.failureOrNull, isA<EngineFailure>());
      expect((r.failureOrNull! as EngineFailure).code, 'PERMISSION_REQUIRED');
    });

    test(
      'category changes reach the engine; search is not DNS-filtered',
      () async {
        final (c, engine) = await make();
        await c.setCategory(ProtectionCategory.gambling, false);
        expect(engine.applied!.isActive(ProtectionCategory.gambling), isFalse);
        expect(
          engine.applied!.networkCategories,
          isNot(contains(ProtectionCategory.unsafeSearch)),
        );
        expect(engine.applied!.networkCategories, hasLength(5));
      },
    );

    test('stats come from the engine', () async {
      final (c, engine) = await make();
      engine.logs.add(
        BlockEvent(
          time: DateTime(2026),
          domain: 'x.test',
          category: ProtectionCategory.sexual,
        ),
      );
      await c.refreshStats();
      expect(c.stats.today, 1);
      expect(c.stats.byCategory[ProtectionCategory.sexual], 1);
    });
  });

  group('EngineSnapshot.fromMap', () {
    test('parses the native status map', () {
      final s = EngineSnapshot.fromMap({
        'vpnState': 'running',
        'dnsFilterActive': true,
        'rulesReady': true,
        'ruleCount': 8,
        'blockingRuleCount': 7,
        'enabledCategories': 5,
        'otherVpnActive': false,
        'privateDnsStrict': true,
        'upstreamAvailable': true,
        'startedAt': 1000,
      });
      expect(s.isActive, isTrue);
      expect(s.privateDnsStrict, isTrue);
      expect(s.startedAt, DateTime.fromMillisecondsSinceEpoch(1000));
    });

    test('wrong types and unknown states fall back to inactive', () {
      final s = EngineSnapshot.fromMap({
        'vpnState': 'warp-speed',
        'dnsFilterActive': 'yes',
        'ruleCount': '8',
      });
      expect(s.vpnState, VpnState.stopped);
      expect(s.isActive, isFalse);
      expect(s.ruleCount, 0);
      expect(
        EngineSnapshot.fromMap({'vpnState': 'permission_required'}).vpnState,
        VpnState.permissionRequired,
      );
    });
  });

  group('NativeProtectionEngine ↔ platform channel', () {
    const method = MethodChannel(ProtectionChannel.methodChannelName);
    final calls = <MethodCall>[];
    late NativeProtectionEngine engine;

    setUp(() {
      calls.clear();
      engine = NativeProtectionEngine(ProtectionChannel(methods: method));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (call) async {
            calls.add(call);
            return switch (call.method) {
              'startProtection' => throw PlatformException(
                code: 'PERMISSION_REQUIRED',
              ),
              'addBlockedDomain'
                  when (call.arguments as Map)['domain'] == 'bad' =>
                throw PlatformException(code: 'INVALID_DOMAIN'),
              'addBlockedDomain' => {
                'domain': 'casino.test',
                'category': 'gambling',
                'action': 'block',
                'source': 'user',
                'updatedAt': 5,
              },
              'getRules' => [
                {'domain': 'ok.test', 'action': 'allow', 'category': 'safe'},
                'garbage',
              ],
              'getBlockedLogs' => [
                {'timestamp': 1000, 'domain': 'a.test', 'category': 'sexual'},
                {'timestamp': 'x', 'domain': 'b.test'},
              ],
              'getStatistics' => {
                'today': 3,
                'last7Days': 9,
                'total': 40,
                'byCategory': {'sexual': 2, 'gambling': 1, 'future': 7},
              },
              'getProtectionStatus' => {'vpnState': 'revoked'},
              // Status-returning methods answer with the status map.
              'setConfiguration' ||
              'stopProtection' ||
              'updateCategory' => {'vpnState': 'stopped'},
              _ => true,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, null);
    });

    test('apply sends only DNS-filterable categories', () async {
      final state = ProtectionState.initial().withCategory(
        ProtectionCategory.drugs,
        false,
        DateTime(2026),
      );
      await engine.apply(state);
      expect(calls.single.method, 'setConfiguration');
      expect(calls.single.arguments, {
        'enabled': true,
        'categories': ['sexual', 'violence', 'gore', 'gambling', 'dangerous'],
      });
    });

    test('platform errors become typed EngineFailures', () async {
      await expectLater(
        engine.start(),
        throwsA(
          isA<EngineFailure>().having(
            (f) => f.code,
            'code',
            'PERMISSION_REQUIRED',
          ),
        ),
      );
      await expectLater(
        engine.addBlockedDomain('bad', ProtectionCategory.sexual),
        throwsA(isA<EngineFailure>()),
      );
    });

    test('rules, logs, stats and status are parsed defensively', () async {
      final rule = await engine.addBlockedDomain(
        'casino.test',
        ProtectionCategory.gambling,
      );
      expect(calls.last.arguments, {
        'domain': 'casino.test',
        'category': 'gambling',
      });
      expect(rule.category, ProtectionCategory.gambling);

      final allowed = await engine.userRules(RuleAction.allow);
      expect(calls.last.arguments, {'action': 'allow', 'source': 'user'});
      expect(allowed.single.domain, 'ok.test');
      expect(allowed.single.category, isNull);

      final logs = await engine.blockedLogs(limit: 5);
      expect(logs, hasLength(1));
      expect(logs.single.category, ProtectionCategory.sexual);

      final stats = await engine.statistics();
      expect(stats.total, 40);
      expect(stats.byCategory, {
        ProtectionCategory.sexual: 2,
        ProtectionCategory.gambling: 1,
      });

      expect((await engine.status()).vpnState, VpnState.revoked);
    });

    test('removeRule calls the method matching the rule action', () async {
      await engine.removeRule(
        const DomainRule(domain: 'x.test', action: RuleAction.allow),
      );
      await engine.removeRule(
        const DomainRule(domain: 'y.test', action: RuleAction.block),
      );
      expect(calls.map((c) => c.method), [
        'removeAllowedDomain',
        'removeBlockedDomain',
      ]);
    });
  });

  group('DomainInput', () {
    test('normalises pasted URLs and www', () {
      expect(
        DomainInput.normalize('https://www.Example.com/a?b'),
        'example.com',
      );
      expect(
        DomainInput.normalize(' sub.example.co.uk. '),
        'sub.example.co.uk',
      );
      expect(DomainInput.normalize('user@example.com:443'), 'example.com');
    });

    test('rejects malformed input', () {
      for (final bad in [
        '',
        'localhost',
        '10.0.0.1',
        '[::1]',
        'exa mple.com',
        'a..b',
        '-a.com',
        'example.123',
        '*.example.com',
        "x';drop table rules;--.com",
      ]) {
        expect(DomainInput.normalize(bad), isNull, reason: bad);
      }
    });

    test('non-ASCII names are passed to the native IDN conversion', () {
      expect(DomainInput.normalize('مثال.إختبار'), 'مثال.إختبار');
    });
  });

  test('Result/guard keeps EngineFailure codes intact', () async {
    final r = await guard<void>(
      () async => throw EngineFailure('LIMIT_REACHED'),
    );
    expect((r as Err).failure, isA<EngineFailure>());
  });
}
