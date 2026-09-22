import '../../../core/platform/protection_channel.dart';
import '../domain/protection.dart';

/// Android implementation of [ProtectionEngine]: VpnService + DNS filter,
/// reached through [ProtectionChannel].
class NativeProtectionEngine implements ProtectionEngine {
  NativeProtectionEngine([ProtectionChannel? channel])
    : _channel = channel ?? ProtectionChannel();

  final ProtectionChannel _channel;

  @override
  bool get isSupported => true;

  @override
  Stream<EngineSnapshot> watch() =>
      _channel.statusStream().map(EngineSnapshot.fromMap);

  @override
  Future<EngineSnapshot> status() async =>
      EngineSnapshot.fromMap(await _channel.getProtectionStatus());

  @override
  Future<void> apply(ProtectionState state) => _channel.setConfiguration(
    enabled: state.enabled,
    categories: [
      for (final c in ProtectionCategory.networkFiltered)
        if (state.isActive(c)) c.id,
    ],
  );

  @override
  Future<bool> hasVpnPermission() => _channel.hasVpnPermission();

  @override
  Future<bool> requestVpnPermission() => _channel.requestVpnPermission();

  @override
  Future<void> start() => _channel.startProtection();

  @override
  Future<void> stop() => _channel.stopProtection();

  @override
  Future<List<DomainRule>> userRules(RuleAction action) async {
    final raw = await _channel.getRules(action: action.name, source: 'user');
    return raw.map(_rule).nonNulls.toList();
  }

  @override
  Future<DomainRule> addBlockedDomain(
    String domain,
    ProtectionCategory category,
  ) async =>
      _rule(await _channel.addBlockedDomain(domain, category.id)) ??
      DomainRule(domain: domain, action: RuleAction.block, category: category);

  @override
  Future<DomainRule> addAllowedDomain(String domain) async =>
      _rule(await _channel.addAllowedDomain(domain)) ??
      DomainRule(domain: domain, action: RuleAction.allow);

  @override
  Future<bool> removeRule(DomainRule rule) => switch (rule.action) {
    RuleAction.block => _channel.removeBlockedDomain(rule.domain),
    RuleAction.allow => _channel.removeAllowedDomain(rule.domain),
  };

  @override
  Future<List<BlockEvent>> blockedLogs({int limit = 200}) async {
    final raw = await _channel.getBlockedLogs(limit: limit);
    return [
      for (final m in raw)
        if (m['domain'] is String && m['timestamp'] is int)
          BlockEvent(
            time: DateTime.fromMillisecondsSinceEpoch(m['timestamp']! as int),
            domain: m['domain']! as String,
            category: ProtectionCategory.fromId('${m['category']}'),
          ),
    ];
  }

  @override
  Future<void> clearLogs() => _channel.clearLogs();

  @override
  Future<ProtectionStats> statistics() async {
    final m = await _channel.getStatistics();
    int count(Object? v) => v is int ? v : 0;
    final byCategory = <ProtectionCategory, int>{};
    final raw = m['byCategory'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final c = ProtectionCategory.fromId('$k');
        if (c != null) byCategory[c] = count(v);
      });
    }
    return ProtectionStats(
      today: count(m['today']),
      last7Days: count(m['last7Days']),
      total: count(m['total']),
      byCategory: byCategory,
    );
  }

  @override
  Future<void> openVpnSettings() => _channel.openVpnSettings();

  @override
  Future<void> eraseAll() => _channel.eraseAll();

  static DomainRule? _rule(Map<Object?, Object?> m) {
    final domain = m['domain'];
    if (domain is! String) return null;
    final action = m['action'] == 'allow' ? RuleAction.allow : RuleAction.block;
    final updated = m['updatedAt'];
    return DomainRule(
      domain: domain,
      action: action,
      category: action == RuleAction.block
          ? ProtectionCategory.fromId('${m['category']}')
          : null,
      updatedAt: updated is int
          ? DateTime.fromMillisecondsSinceEpoch(updated)
          : null,
    );
  }
}
