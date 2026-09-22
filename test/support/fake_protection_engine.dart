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
    protected.clear();
    await stop();
  }

  // ---- Phase 3 ----
  SearchSettings search = const SearchSettings();
  AccessibilityStatus a11y = AccessibilityStatus.disabled;
  final protected = <ProtectedApp>[];
  final installed = <InstalledApp>[
    const InstalledApp(packageName: 'com.example.social', label: 'Social'),
    const InstalledApp(packageName: 'com.example.game', label: 'Game'),
  ];
  final submittedEngines = <SearchEngineId>[];

  /// Keywords the fake treats as blocked, mirroring the native rule layer.
  static const _blockedWords = {
    'porn': ProtectionCategory.sexual,
    'casino': ProtectionCategory.gambling,
    'قمار': ProtectionCategory.gambling,
  };

  @override
  Future<SearchSettings> searchSettings() async => search;

  @override
  Future<SearchSettings> setSearchSettings(SearchSettings s) async =>
      search = s;

  @override
  Future<SearchCheck> submitSearch(String query, SearchEngineId engine) async {
    if (query.trim().isEmpty) throw EngineFailure('INVALID_ARGUMENT');
    submittedEngines.add(engine);
    final lower = query.toLowerCase();
    ProtectionCategory? hit;
    for (final e in _blockedWords.entries) {
      if (lower.split(RegExp(r'\s+')).contains(e.key)) hit = e.value;
    }
    final on = search.enabled && (applied?.enabled ?? true);
    final blocked = on && hit != null && (applied?.isActive(hit) ?? true);
    if (blocked) {
      // Privacy-safe log: rule id + hash, never the query.
      logs.insert(
        0,
        BlockEvent(
          time: DateTime(2026),
          domain: 'kw01#0000abcd',
          category: hit,
          source: EventSourceKind.search,
          confidence: 1,
          ruleType: 'keyword',
        ),
      );
    }
    return SearchCheck(
      action: blocked ? RuleAction.block : RuleAction.allow,
      category: hit,
      confidence: hit == null ? 0 : 1,
      ruleType: 'keyword',
      reason: blocked ? 'category_blocked' : 'unknown',
      opened: !blocked,
    );
  }

  @override
  Future<List<ProtectedApp>> protectedApps() async => List.of(protected);

  @override
  Future<List<InstalledApp>> launchableApps() async => installed;

  @override
  Future<ProtectedApp> addProtectedApp(String packageName) async {
    if (!RegExp(r'^[a-zA-Z][\w]*(\.[a-zA-Z][\w]*)+$').hasMatch(packageName)) {
      throw EngineFailure('INVALID_PACKAGE');
    }
    if (packageName == 'com.safeguard.app' ||
        packageName == 'com.android.settings') {
      throw EngineFailure('PACKAGE_NOT_ALLOWED');
    }
    if (protected.any((a) => a.packageName == packageName)) {
      throw EngineFailure('DUPLICATE_PACKAGE');
    }
    final app = installed.where((a) => a.packageName == packageName);
    if (app.isEmpty) throw EngineFailure('PACKAGE_NOT_INSTALLED');
    final p = ProtectedApp(packageName: packageName, label: app.first.label);
    protected.add(p);
    return p;
  }

  @override
  Future<bool> removeProtectedApp(String packageName) async {
    final before = protected.length;
    protected.removeWhere((a) => a.packageName == packageName);
    return protected.length != before;
  }

  @override
  Future<AccessibilityStatus> accessibilityStatus() async => a11y;

  @override
  Future<AccessibilityStatus> setAccessibilityDisclosure({
    required bool accepted,
  }) async {
    if (a11y != AccessibilityStatus.enabled) {
      a11y = accepted
          ? AccessibilityStatus.disabled
          : AccessibilityStatus.permissionDenied;
    }
    return a11y;
  }

  int accessibilitySettingsOpened = 0;

  @override
  Future<void> openAccessibilitySettings() async =>
      accessibilitySettingsOpened++;
}
