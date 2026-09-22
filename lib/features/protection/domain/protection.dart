import 'dart:convert';

/// Content categories SafeGuard can filter. [id] is the stable storage key
/// and must never change once shipped.
enum ProtectionCategory {
  sexual('sexual'),
  violence('violence'),
  gore('gore'),
  gambling('gambling'),
  drugs('drugs'),
  dangerous('dangerous'),
  unsafeSearch('unsafe_search');

  const ProtectionCategory(this.id);
  final String id;

  /// Whether DNS filtering enforces this category. Search filtering needs
  /// a different mechanism (SafeSearch enforcement, Phase 3), so it is
  /// stored as a preference but not sent to the network engine.
  bool get isNetworkFiltered => this != unsafeSearch;

  static List<ProtectionCategory> get networkFiltered =>
      values.where((c) => c.isNetworkFiltered).toList();

  static ProtectionCategory? fromId(String id) {
    for (final c in values) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// The user's protection policy. This is *intent*: what should be blocked.
/// Whether it is actually enforced depends on [EngineSnapshot].
class ProtectionState {
  const ProtectionState({
    required this.enabled,
    required this.categories,
    this.updatedAt,
  });

  /// Secure default: everything on.
  factory ProtectionState.initial() => ProtectionState(
    enabled: true,
    categories: {for (final c in ProtectionCategory.values) c: true},
  );

  final bool enabled;
  final Map<ProtectionCategory, bool> categories;
  final DateTime? updatedAt;

  bool isActive(ProtectionCategory c) => categories[c] ?? true;

  int get activeCount => ProtectionCategory.values.where(isActive).length;

  /// Categories the DNS engine should block (empty when disabled).
  Set<ProtectionCategory> get networkCategories => enabled
      ? ProtectionCategory.networkFiltered.where(isActive).toSet()
      : const {};

  int get activeNetworkCount =>
      ProtectionCategory.networkFiltered.where(isActive).length;

  /// Categories that are effectively filtered right now.
  Set<ProtectionCategory> get effectiveCategories =>
      enabled ? ProtectionCategory.values.where(isActive).toSet() : const {};

  ProtectionState copyWith({
    bool? enabled,
    Map<ProtectionCategory, bool>? categories,
    DateTime? updatedAt,
  }) {
    return ProtectionState(
      enabled: enabled ?? this.enabled,
      categories: categories ?? this.categories,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  ProtectionState withCategory(ProtectionCategory c, bool value, DateTime at) {
    return copyWith(categories: {...categories, c: value}, updatedAt: at);
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'categories': {for (final e in categories.entries) e.key.id: e.value},
    'updatedAt': updatedAt?.toIso8601String(),
  };

  String encode() => jsonEncode(toJson());

  /// Unknown category ids are ignored and missing ones default to ON, so a
  /// newly added category is protected by default after an update.
  factory ProtectionState.fromJson(Map<String, dynamic> json) {
    final stored = (json['categories'] as Map<String, dynamic>? ?? const {});
    final categories = {for (final c in ProtectionCategory.values) c: true};
    stored.forEach((id, value) {
      final category = ProtectionCategory.fromId(id);
      if (category != null && value is bool) categories[category] = value;
    });
    final updated = json['updatedAt'] as String?;
    return ProtectionState(
      enabled: json['enabled'] as bool? ?? true,
      categories: categories,
      updatedAt: updated == null ? null : DateTime.tryParse(updated),
    );
  }
}

enum VpnState {
  stopped,
  starting,
  running,
  stopping,

  /// VPN consent not granted (or withdrawn).
  permissionRequired,

  /// Another VPN took over, or the user disconnected from system settings.
  revoked,
  error,

  /// No native engine on this platform (tests, non-Android).
  unsupported;

  static VpnState fromName(String? name) => switch (name) {
    'stopped' => stopped,
    'starting' => starting,
    'running' => running,
    'stopping' => stopping,
    'permission_required' => permissionRequired,
    'revoked' => revoked,
    'error' => error,
    _ => stopped,
  };
}

/// Live state of the native protection stack.
class EngineSnapshot {
  const EngineSnapshot({
    required this.vpnState,
    this.dnsFilterActive = false,
    this.rulesReady = false,
    this.ruleCount = 0,
    this.blockingRuleCount = 0,
    this.enabledCategories = 0,
    this.protectionEnabled = false,
    this.otherVpnActive = false,
    this.privateDnsStrict = false,
    this.upstreamAvailable = false,
    this.lastError,
    this.startedAt,
  });

  static const unsupported = EngineSnapshot(vpnState: VpnState.unsupported);
  static const initial = EngineSnapshot(vpnState: VpnState.stopped);

  final VpnState vpnState;
  final bool dnsFilterActive;
  final bool rulesReady;
  final int ruleCount;
  final int blockingRuleCount;
  final int enabledCategories;
  final bool protectionEnabled;
  final bool otherVpnActive;
  final bool privateDnsStrict;
  final bool upstreamAvailable;
  final String? lastError;
  final DateTime? startedAt;

  bool get isSupported => vpnState != VpnState.unsupported;

  /// VPN up, DNS decisions being made, rules loaded.
  bool get isActive =>
      vpnState == VpnState.running && dnsFilterActive && rulesReady;

  bool get isTransitioning =>
      vpnState == VpnState.starting || vpnState == VpnState.stopping;

  /// Parses the map sent by the native `ProtectionStatus.toMap()`. Missing
  /// or wrongly-typed fields fall back to safe (inactive) values.
  factory EngineSnapshot.fromMap(Map<Object?, Object?> m) {
    T? get<T>(String k) => m[k] is T ? m[k] as T : null;
    final started = get<int>('startedAt');
    return EngineSnapshot(
      vpnState: VpnState.fromName(get<String>('vpnState')),
      dnsFilterActive: get<bool>('dnsFilterActive') ?? false,
      rulesReady: get<bool>('rulesReady') ?? false,
      ruleCount: get<int>('ruleCount') ?? 0,
      blockingRuleCount: get<int>('blockingRuleCount') ?? 0,
      enabledCategories: get<int>('enabledCategories') ?? 0,
      protectionEnabled: get<bool>('protectionEnabled') ?? false,
      otherVpnActive: get<bool>('otherVpnActive') ?? false,
      privateDnsStrict: get<bool>('privateDnsStrict') ?? false,
      upstreamAvailable: get<bool>('upstreamAvailable') ?? false,
      lastError: get<String>('lastError'),
      startedAt: started == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(started),
    );
  }
}

/// One blocked lookup: when, which domain, which category. Nothing else is
/// recorded.
class BlockEvent {
  const BlockEvent({
    required this.time,
    required this.domain,
    required this.category,
  });

  final DateTime time;
  final String domain;

  /// Null for categories this app version doesn't know.
  final ProtectionCategory? category;
}

class ProtectionStats {
  const ProtectionStats({
    this.today,
    this.last7Days,
    this.total,
    this.byCategory = const {},
  });

  /// No engine: the UI shows a placeholder, never invented numbers.
  static const unavailable = ProtectionStats();

  final int? today;
  final int? last7Days;
  final int? total;

  /// Last 30 days, per category.
  final Map<ProtectionCategory, int> byCategory;

  bool get isAvailable => today != null;
}

enum RuleAction { allow, block }

/// A user-managed domain rule (blocklist or allowlist entry).
class DomainRule {
  const DomainRule({
    required this.domain,
    required this.action,
    this.category,
    this.updatedAt,
  });

  final String domain;
  final RuleAction action;

  /// Content category for blocked domains; null for allowed ones.
  final ProtectionCategory? category;
  final DateTime? updatedAt;
}

/// Port to the enforcement layer. On Android this is the native VpnService
/// + DNS filter behind a platform channel ([NativeProtectionEngine]).
abstract interface class ProtectionEngine {
  bool get isSupported;

  /// Status pushes from the native side.
  Stream<EngineSnapshot> watch();
  Future<EngineSnapshot> status();

  /// Mirrors the policy to the native side (it must work without Flutter).
  Future<void> apply(ProtectionState state);

  Future<bool> hasVpnPermission();

  /// Shows the official system VPN consent dialog. True if granted.
  Future<bool> requestVpnPermission();
  Future<void> start();
  Future<void> stop();

  Future<List<DomainRule>> userRules(RuleAction action);
  Future<DomainRule> addBlockedDomain(
    String domain,
    ProtectionCategory category,
  );
  Future<DomainRule> addAllowedDomain(String domain);
  Future<bool> removeRule(DomainRule rule);

  Future<List<BlockEvent>> blockedLogs({int limit = 200});
  Future<void> clearLogs();
  Future<ProtectionStats> statistics();

  /// Opens Android's VPN settings (for "Always-on VPN").
  Future<void> openVpnSettings();

  /// Stops the VPN and deletes native rules, logs and config.
  Future<void> eraseAll();
}

/// Engine for platforms without the native layer (tests, previews): reports
/// itself unsupported and enforces nothing.
class UnavailableProtectionEngine implements ProtectionEngine {
  const UnavailableProtectionEngine();

  @override
  bool get isSupported => false;
  @override
  Stream<EngineSnapshot> watch() => const Stream.empty();
  @override
  Future<EngineSnapshot> status() async => EngineSnapshot.unsupported;
  @override
  Future<void> apply(ProtectionState state) async {}
  @override
  Future<bool> hasVpnPermission() async => false;
  @override
  Future<bool> requestVpnPermission() async => false;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<List<DomainRule>> userRules(RuleAction action) async => const [];
  @override
  Future<DomainRule> addBlockedDomain(String d, ProtectionCategory c) async =>
      DomainRule(domain: d, action: RuleAction.block, category: c);
  @override
  Future<DomainRule> addAllowedDomain(String d) async =>
      DomainRule(domain: d, action: RuleAction.allow);
  @override
  Future<bool> removeRule(DomainRule rule) async => false;
  @override
  Future<List<BlockEvent>> blockedLogs({int limit = 200}) async => const [];
  @override
  Future<void> clearLogs() async {}
  @override
  Future<ProtectionStats> statistics() async => ProtectionStats.unavailable;
  @override
  Future<void> openVpnSettings() async {}
  @override
  Future<void> eraseAll() async {}
}

abstract interface class ProtectionRepository {
  Future<ProtectionState> load();
  Future<void> save(ProtectionState state);
}
