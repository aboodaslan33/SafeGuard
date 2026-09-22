import 'dart:async';

import 'package:safeguard/core/error/failures.dart';
import 'package:safeguard/features/protection/domain/protection.dart';
import 'package:safeguard/features/rules/domain/domain_input.dart';

/// In-memory stand-in for the native engine, with the same contract:
/// start() fails without consent, status is pushed on changes, rules are
/// validated, logs and stats are kept locally.
class FakeProtectionEngine implements ProtectionEngine {
  FakeProtectionEngine({
    this.permissionGranted = false,
    this.grantOnRequest = true,
  });

  bool permissionGranted;
  bool grantOnRequest;
  int permissionRequests = 0;
  ProtectionState? applied;
  final rules = <DomainRule>[];
  final logs = <BlockEvent>[];
  EngineSnapshot _snapshot = EngineSnapshot.initial;
  final _controller = StreamController<EngineSnapshot>.broadcast();

  EngineSnapshot get current => _snapshot;

  void emit(EngineSnapshot s) {
    _snapshot = s;
    _controller.add(s);
  }

  @override
  bool get isSupported => true;
  @override
  Stream<EngineSnapshot> watch() => _controller.stream;
  @override
  Future<EngineSnapshot> status() async => _snapshot;
  @override
  Future<void> apply(ProtectionState state) async => applied = state;
  @override
  Future<bool> hasVpnPermission() async => permissionGranted;

  @override
  Future<bool> requestVpnPermission() async {
    permissionRequests++;
    permissionGranted = grantOnRequest;
    return permissionGranted;
  }

  @override
  Future<void> start() async {
    if (!permissionGranted) {
      emit(const EngineSnapshot(vpnState: VpnState.permissionRequired));
      throw EngineFailure('PERMISSION_REQUIRED');
    }
    emit(
      EngineSnapshot(
        vpnState: VpnState.running,
        dnsFilterActive: true,
        rulesReady: true,
        ruleCount: 3,
        blockingRuleCount: 2,
        protectionEnabled: true,
        upstreamAvailable: true,
        enabledCategories: applied?.networkCategories.length ?? 6,
      ),
    );
  }

  @override
  Future<void> stop() async =>
      emit(const EngineSnapshot(vpnState: VpnState.stopped, rulesReady: true));

  @override
  Future<List<DomainRule>> userRules(RuleAction action) async =>
      rules.where((r) => r.action == action).toList();

  DomainRule _add(String input, RuleAction action, ProtectionCategory? c) {
    final domain = DomainInput.normalize(input);
    if (domain == null) throw EngineFailure('INVALID_DOMAIN');
    rules.removeWhere((r) => r.domain == domain);
    final rule = DomainRule(domain: domain, action: action, category: c);
    rules.add(rule);
    return rule;
  }

  @override
  Future<DomainRule> addBlockedDomain(String d, ProtectionCategory c) async =>
      _add(d, RuleAction.block, c);
  @override
  Future<DomainRule> addAllowedDomain(String d) async =>
      _add(d, RuleAction.allow, null);

  @override
  Future<bool> removeRule(DomainRule rule) async {
    final before = rules.length;
    rules.removeWhere(
      (r) => r.domain == rule.domain && r.action == rule.action,
    );
    return rules.length != before;
  }

  @override
  Future<List<BlockEvent>> blockedLogs({int limit = 200}) async =>
      logs.take(limit).toList();
  @override
  Future<void> clearLogs() async => logs.clear();

  @override
  Future<ProtectionStats> statistics() async {
    final byCategory = <ProtectionCategory, int>{};
    for (final e in logs) {
      final c = e.category;
      if (c != null) byCategory[c] = (byCategory[c] ?? 0) + 1;
    }
    return ProtectionStats(
      today: logs.length,
      last7Days: logs.length,
      total: logs.length,
      byCategory: byCategory,
    );
  }

  @override
  Future<void> openVpnSettings() async {}

  @override
  Future<void> eraseAll() async {
    rules.clear();
    logs.clear();
    await stop();
  }
}
