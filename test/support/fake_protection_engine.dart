import 'dart:async';

import 'package:safeguard/core/error/failures.dart';
import 'package:safeguard/core/i18n/i18n.dart';
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

  /// Mirrors native `UserRules`: duplicates and cross-list conflicts are
  /// refused, not silently replaced.
  DomainRule _add(
    String input,
    RuleAction action,
    ProtectionCategory? c, {
    bool includeSubdomains = true,
  }) {
    final domain = DomainInput.normalize(input)
        ?.replaceFirst(RegExp(r'^www\.'), '');
    if (domain == null) throw EngineFailure('INVALID_DOMAIN');
    for (final r in rules) {
      if (r.domain == domain) {
        throw EngineFailure(
          r.action == action ? 'DUPLICATE_DOMAIN' : 'IN_OTHER_LIST',
        );
      }
    }
    final rule = DomainRule(
      domain: domain,
      action: action,
      category: c,
      includeSubdomains: action == RuleAction.block || includeSubdomains,
    );
    rules.add(rule);
    return rule;
  }

  @override
  Future<DomainRule> addBlockedDomain(String d, ProtectionCategory? c) async =>
      _add(d, RuleAction.block, c);
  @override
  Future<DomainRule> addAllowedDomain(
    String d, {
    bool includeSubdomains = false,
  }) async =>
      _add(d, RuleAction.allow, null, includeSubdomains: includeSubdomains);

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

  LogRetention retention = LogRetention.defaultValue;
  AppLanguage? uiLanguage;

  @override
  Future<void> setUiLanguage(AppLanguage language) async =>
      uiLanguage = language;

  @override
  Future<LogRetention> logRetention() async => retention;

  @override
  Future<LogRetention> setLogRetention(LogRetention value) async {
    retention = value;
    if (value == LogRetention.never) logs.clear();
    return value;
  }

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
    keywordList.clear();
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

  /// Phrases the fake "model" scores (category, score), after the rules.
  static const _aiWords = {
    'brawl': (ProtectionCategory.violence, 0.95),
    'risque': (ProtectionCategory.sexual, 0.80),
  };

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
    // AI layer (after the rules), mirroring AiSearchFilterService.
    if (on && !blocked && ai.enabled) {
      for (final e in _aiWords.entries) {
        final category = e.value.$1;
        if (!lower.contains(e.key) || !(applied?.isActive(category) ?? true)) {
          continue;
        }
        if (e.value.$2 >= ai.threshold(category)) {
          logs.insert(
            0,
            BlockEvent(
              time: DateTime(2026),
              domain: 'sg-text-1#0000abcd',
              category: category,
              source: EventSourceKind.ai,
              confidence: e.value.$2,
              ruleType: 'ai_text',
            ),
          );
          aiStats = AiStatistics(
            detections: aiStats.detections + 1,
            blocks: aiStats.blocks + 1,
            falsePositiveReports: aiStats.falsePositiveReports,
          );
          return SearchCheck(
            action: RuleAction.block,
            category: category,
            confidence: e.value.$2,
            ruleType: 'ai_text',
            reason: 'ai_threshold',
            opened: false,
          );
        }
      }
    }
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

  int batterySettingsOpened = 0;
  int privateDnsSettingsOpened = 0;
  Map<String, Object?> diagnosticsData = {
    'androidRelease': '13',
    'sdkInt': 33,
    'manufacturer': 'TestCo',
    'model': 'X1',
    'vpnState': 'running',
    'dnsFilterActive': true,
    'bundledLists': {'gambling': 342623},
    'userRules': 2,
    'batteryOptimizationIgnored': false,
    'databaseOk': true,
  };

  AlertsState alerts = const AlertsState();
  int notificationRequests = 0;
  bool grantNotifications = true;

  @override
  Future<AlertsState> alertsState() async => alerts;

  @override
  Future<AlertsState> setAlertsEnabled(bool enabled) async =>
      alerts = AlertsState(enabled: enabled, permission: alerts.permission);

  @override
  Future<bool> requestNotificationPermission() async {
    notificationRequests++;
    alerts = AlertsState(
      enabled: alerts.enabled,
      permission: grantNotifications,
    );
    return grantNotifications;
  }

  DecisionTraceSnapshot trace = const DecisionTraceSnapshot();

  @override
  Future<DecisionTraceSnapshot> decisionTrace() async => trace;

  @override
  Future<void> setDecisionTraceEnabled(bool enabled) async =>
      trace = DecisionTraceSnapshot(
        enabled: enabled,
        entries: enabled ? trace.entries : const [],
      );

  @override
  Future<void> openBatterySettings() async => batterySettingsOpened++;

  @override
  Future<void> openPrivateDnsSettings() async => privateDnsSettingsOpened++;

  @override
  Future<Map<String, Object?>> diagnostics() async => {
    ...diagnosticsData,
    'vpnState': _snapshot.vpnState.name,
  };

  @override
  Future<void> openAccessibilitySettings() async =>
      accessibilitySettingsOpened++;

  // ---- Phase 4 ----
  AiSettings ai = const AiSettings(
    textModelAvailable: true,
    textModelId: 'sg-text-1',
  );
  AiStatistics aiStats = const AiStatistics();
  final reports = <(EventSourceKind, ProtectionCategory, double)>[];
  ImageCheck imageResult = const ImageCheck(
    status: ImageCheckStatus.unavailable,
    error: 'no_model',
  );
  int imageChecks = 0;

  @override
  Future<AiSettings> aiSettings() async => ai;

  @override
  Future<AiSettings> setAiSettings(AiSettings s) async => ai = s;

  @override
  Future<AiStatistics> aiStatistics() async => aiStats;

  @override
  Future<void> reportFalsePositive({
    required EventSourceKind source,
    required ProtectionCategory category,
    required double confidence,
  }) async {
    reports.add((source, category, confidence));
    aiStats = AiStatistics(
      detections: aiStats.detections,
      blocks: aiStats.blocks,
      falsePositiveReports: aiStats.falsePositiveReports + 1,
    );
  }

  @override
  Future<ImageCheck> checkImage() async {
    imageChecks++;
    return imageResult;
  }

  // ---- Phase 5 ----
  ProtectionMode nativeMode = ProtectionMode.custom;
  Duration pausedFor = Duration.zero;
  bool safeMode = false;
  final incidents = <ProtectionIncident>[];
  final keywordList = <CustomKeyword>[];
  int recoverCalls = 0;
  int resets = 0;
  String? exported;
  ExportResult exportResult = ExportResult.saved;
  DetailedStats detailed = const DetailedStats();
  List<LayerHealth> layers = const [
    LayerHealth(HealthLayer.vpn, LayerState.active),
    LayerHealth(HealthLayer.dns, LayerState.active),
    LayerHealth(HealthLayer.rules, LayerState.active),
    LayerHealth(HealthLayer.search, LayerState.active),
    LayerHealth(HealthLayer.ai, LayerState.active),
  ];
  OverallHealth overall = OverallHealth.protected;

  HealthReport get _report => HealthReport(
    overall: overall,
    layers: layers,
    mode: applied?.mode ?? nativeMode,
    pausedRemaining: pausedFor,
    safeMode: safeMode,
    incidents: List.of(incidents),
  );

  @override
  Future<HealthReport> health() async => _report;

  @override
  Future<void> acknowledgeIncidents(DateTime upTo) async =>
      incidents.removeWhere((i) => !i.time.isAfter(upTo));

  @override
  Future<bool> tryRecover() async {
    recoverCalls++;
    return false;
  }

  @override
  Future<HealthReport> startPause(int minutes) async {
    if (![5, 10, 30].contains(minutes)) throw EngineFailure('INVALID_ARGUMENT');
    pausedFor = Duration(minutes: minutes);
    logs.insert(
      0,
      BlockEvent(
        time: DateTime(2026),
        domain: 'unlock:${minutes}m',
        category: null,
        source: EventSourceKind.manual,
        ruleType: 'temporary_unlock',
        isBlock: false,
        categoryId: 'unknown',
      ),
    );
    return _report;
  }

  @override
  Future<HealthReport> endPause() async {
    pausedFor = Duration.zero;
    return _report;
  }

  @override
  Future<HealthReport> enterSafeMode() async {
    safeMode = true;
    overall = OverallHealth.notProtected;
    await stop();
    return _report;
  }

  @override
  Future<HealthReport> resetProtection() async {
    resets++;
    pausedFor = Duration.zero;
    safeMode = false;
    return _report;
  }

  @override
  Future<DetailedStats> detailedStatistics() async => detailed;

  @override
  Future<List<CustomKeyword>> keywords() async => List.of(keywordList);

  @override
  Future<CustomKeyword> addKeyword(
    String keyword,
    ProtectionCategory? category,
  ) async {
    final k = keyword.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (k.isEmpty || k.split(' ').length > 5) {
      throw EngineFailure('INVALID_KEYWORD');
    }
    if (!k.contains(' ') && k.length < 3) {
      throw EngineFailure('KEYWORD_TOO_SHORT');
    }
    if (keywordList.any((e) => e.keyword == k)) {
      throw EngineFailure('DUPLICATE_KEYWORD');
    }
    final item = CustomKeyword(
      id: keywordList.length + 1,
      keyword: k,
      category: category,
    );
    keywordList.add(item);
    return item;
  }

  @override
  Future<bool> removeKeyword(int id) async {
    final before = keywordList.length;
    keywordList.removeWhere((k) => k.id == id);
    return keywordList.length != before;
  }

  @override
  Future<ExportResult> saveExport(String json) async {
    exported = json;
    return exportResult;
  }
}
