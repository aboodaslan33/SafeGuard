import '../../../core/error/failures.dart';
import '../../../core/i18n/i18n.dart';
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
    // The user's own choices; native resolves NORMAL/STRICT presets.
    categories: [
      for (final c in ProtectionCategory.networkFiltered)
        if (state.isChosen(c)) c.id,
    ],
    mode: state.mode.name,
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
    ProtectionCategory? category,
  ) async =>
      _rule(
        await _channel.addBlockedDomain(domain, category?.id ?? 'custom'),
      ) ??
      DomainRule(domain: domain, action: RuleAction.block, category: category);

  @override
  Future<DomainRule> addAllowedDomain(
    String domain, {
    bool includeSubdomains = false,
  }) async =>
      _rule(
        await _channel.addAllowedDomain(
          domain,
          includeSubdomains: includeSubdomains,
        ),
      ) ??
      DomainRule(
        domain: domain,
        action: RuleAction.allow,
        includeSubdomains: includeSubdomains,
      );

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
            source: EventSourceKind.fromId(m['source']),
            confidence: m['confidence'] is num
                ? (m['confidence']! as num).toDouble()
                : 1.0,
            ruleType: m['ruleType'] is String
                ? m['ruleType']! as String
                : 'domain',
            isBlock: m['action'] != 'allow',
            categoryId: m['category'] is String
                ? m['category']! as String
                : null,
          ),
    ];
  }

  @override
  Future<void> clearLogs() => _channel.clearLogs();

  @override
  Future<void> setUiLanguage(AppLanguage language) =>
      _channel.setUiLanguage(language.name);

  @override
  Future<LogRetention> logRetention() async =>
      LogRetention.fromId(await _channel.getLogRetention()) ??
      LogRetention.defaultValue;

  @override
  Future<LogRetention> setLogRetention(LogRetention value) async =>
      LogRetention.fromId(await _channel.setLogRetention(value.id)) ?? value;

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

  @override
  Future<SearchSettings> searchSettings() async =>
      SearchSettings.fromMap(await _channel.getSearchSettings());

  @override
  Future<SearchSettings> setSearchSettings(SearchSettings settings) async =>
      SearchSettings.fromMap(
        await _channel.setSearchSettings(settings.toMap()),
      );

  @override
  Future<SearchCheck> submitSearch(String query, SearchEngineId engine) async {
    final m = await _channel.submitSearch(query, engine.name);
    return SearchCheck(
      action: m['action'] == 'block' ? RuleAction.block : RuleAction.allow,
      category: ProtectionCategory.fromId('${m['category']}'),
      confidence: m['confidence'] is num
          ? (m['confidence']! as num).toDouble()
          : 0,
      ruleType: m['ruleType'] is String ? m['ruleType']! as String : 'keyword',
      reason: m['reason'] is String ? m['reason']! as String : '',
      opened: m['opened'] == true,
    );
  }

  @override
  Future<List<ProtectedApp>> protectedApps() async =>
      (await _channel.getProtectedApps()).map(_app).nonNulls.toList();

  @override
  Future<List<InstalledApp>> launchableApps() async => [
    for (final m in await _channel.getLaunchableApps())
      if (m['packageName'] is String)
        InstalledApp(
          packageName: m['packageName']! as String,
          label: m['label'] is String
              ? m['label']! as String
              : m['packageName']! as String,
        ),
  ];

  @override
  Future<ProtectedApp> addProtectedApp(String packageName) async =>
      _app(await _channel.addProtectedApp(packageName)) ??
      ProtectedApp(packageName: packageName, label: packageName);

  @override
  Future<bool> removeProtectedApp(String packageName) =>
      _channel.removeProtectedApp(packageName);

  @override
  Future<AccessibilityStatus> accessibilityStatus() async =>
      AccessibilityStatus.fromId(
        (await _channel.getAccessibilityStatus())['state'],
      );

  @override
  Future<AccessibilityStatus> setAccessibilityDisclosure({
    required bool accepted,
  }) async => AccessibilityStatus.fromId(
    (await _channel.setAccessibilityDisclosure(accepted))['state'],
  );

  @override
  Future<void> openAccessibilitySettings() =>
      _channel.openAccessibilitySettings();

  @override
  Future<void> openBatterySettings() => _channel.openBatterySettings();

  @override
  Future<void> openPrivateDnsSettings() => _channel.openPrivateDnsSettings();

  @override
  Future<Map<String, Object?>> diagnostics() async => {
    for (final e in (await _channel.getDiagnostics()).entries)
      if (e.key is String) e.key! as String: e.value,
  };

  static ProtectedApp? _app(Map<Object?, Object?> m) {
    final pkg = m['packageName'];
    if (pkg is! String) return null;
    final added = m['addedAt'];
    return ProtectedApp(
      packageName: pkg,
      label: m['label'] is String ? m['label']! as String : pkg,
      addedAt: added is int ? DateTime.fromMillisecondsSinceEpoch(added) : null,
    );
  }

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
      includeSubdomains: m['includeSubdomains'] != false,
    );
  }

  @override
  Future<AiSettings> aiSettings() async =>
      AiSettings.fromMap(await _channel.getAiSettings());

  @override
  Future<AiSettings> setAiSettings(AiSettings settings) async =>
      AiSettings.fromMap(await _channel.setAiSettings(settings.toMap()));

  @override
  Future<AiStatistics> aiStatistics() async =>
      AiStatistics.fromMap(await _channel.getAiStatistics());

  @override
  Future<void> reportFalsePositive({
    required EventSourceKind source,
    required ProtectionCategory category,
    required double confidence,
  }) => _channel.reportFalsePositive(
    source: source.name,
    category: category.id,
    confidence: confidence,
  );

  @override
  Future<ImageCheck> checkImage() async =>
      ImageCheck.fromMap(await _channel.checkImage());

  @override
  Future<HealthReport> health() async =>
      HealthReport.fromMap(await _channel.getHealth());

  @override
  Future<void> acknowledgeIncidents(DateTime upTo) =>
      _channel.acknowledgeIncidents(upTo.millisecondsSinceEpoch);

  @override
  Future<bool> tryRecover() => _channel.tryRecover();

  @override
  Future<HealthReport> startPause(int minutes) async =>
      HealthReport.fromMap(await _channel.startPause(minutes));

  @override
  Future<HealthReport> endPause() async =>
      HealthReport.fromMap(await _channel.endPause());

  @override
  Future<HealthReport> enterSafeMode() async =>
      HealthReport.fromMap(await _channel.enterSafeMode());

  @override
  Future<HealthReport> resetProtection() async =>
      HealthReport.fromMap(await _channel.resetProtection());

  @override
  Future<DetailedStats> detailedStatistics() async =>
      DetailedStats.fromMap(await _channel.getDetailedStatistics());

  @override
  Future<List<CustomKeyword>> keywords() async => (await _channel.getKeywords())
      .map(CustomKeyword.fromMap)
      .nonNulls
      .toList();

  @override
  Future<CustomKeyword> addKeyword(
    String keyword,
    ProtectionCategory? category,
  ) async =>
      CustomKeyword.fromMap(
        await _channel.addKeyword(keyword, category?.id ?? 'custom'),
      ) ??
      (throw EngineFailure('INTERNAL'));

  @override
  Future<bool> removeKeyword(int id) => _channel.removeKeyword(id);

  @override
  Future<ExportResult> saveExport(String json) async {
    final r = await _channel.saveExport(json);
    return switch (r['status']) {
      'saved' => ExportResult.saved,
      'cancelled' => ExportResult.cancelled,
      _ => ExportResult.failed,
    };
  }
}
