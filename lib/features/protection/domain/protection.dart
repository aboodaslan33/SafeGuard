import 'dart:convert';

import '../../ai/domain/ai_models.dart';
import 'advanced_models.dart';

export '../../ai/domain/ai_models.dart';
export 'advanced_models.dart';

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
    this.mode = ProtectionMode.custom,
    this.updatedAt,
  });

  /// Secure default: everything on, CUSTOM mode (as protective as NORMAL,
  /// and editable; NORMAL/STRICT are opt-in presets).
  factory ProtectionState.initial() => ProtectionState(
    enabled: true,
    categories: {for (final c in ProtectionCategory.values) c: true},
  );

  final bool enabled;

  /// The user's own category choices (enforced only in CUSTOM mode).
  final Map<ProtectionCategory, bool> categories;
  final ProtectionMode mode;
  final DateTime? updatedAt;

  /// Whether [c] is enforced: presets enforce every category.
  bool isActive(ProtectionCategory c) =>
      mode.isPreset || (categories[c] ?? true);

  /// The user's stored choice, whatever the mode.
  bool isChosen(ProtectionCategory c) => categories[c] ?? true;

  int get activeCount => ProtectionCategory.values.where(isActive).length;

  /// The user's categories sent to native (which resolves the mode).
  Set<ProtectionCategory> get networkCategories => enabled
      ? ProtectionCategory.networkFiltered.where(isChosen).toSet()
      : const {};

  int get activeNetworkCount =>
      ProtectionCategory.networkFiltered.where(isActive).length;

  /// Categories that are effectively filtered right now.
  Set<ProtectionCategory> get effectiveCategories =>
      enabled ? ProtectionCategory.values.where(isActive).toSet() : const {};

  ProtectionState copyWith({
    bool? enabled,
    Map<ProtectionCategory, bool>? categories,
    ProtectionMode? mode,
    DateTime? updatedAt,
  }) {
    return ProtectionState(
      enabled: enabled ?? this.enabled,
      categories: categories ?? this.categories,
      mode: mode ?? this.mode,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  ProtectionState withCategory(ProtectionCategory c, bool value, DateTime at) {
    return copyWith(categories: {...categories, c: value}, updatedAt: at);
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'categories': {for (final e in categories.entries) e.key.id: e.value},
    'mode': mode.name,
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
      // Saved before modes existed → CUSTOM, so nothing changes for them.
      mode: ProtectionMode.fromId(json['mode']),
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
/// Where a protection event came from.
enum EventSourceKind {
  dns,
  search,
  app,

  /// On-device AI classification (Phase 4).
  ai,
  manual;

  static EventSourceKind fromId(Object? id) =>
      values.firstWhere((v) => v.name == id, orElse: () => dns);
}

/// One protection event. Contains only: time, source, category, action,
/// confidence, rule type and a non-sensitive subject (DNS: the domain;
/// search: a rule id + keyed short hash, never the query; app: the package).
class BlockEvent {
  const BlockEvent({
    required this.time,
    required this.domain,
    required this.category,
    this.source = EventSourceKind.dns,
    this.confidence = 1.0,
    this.ruleType = 'domain',
    this.isBlock = true,
    this.categoryId,
  });

  final DateTime time;

  /// The event subject (see class doc). Named `domain` since Phase 2.
  final String domain;

  /// Null for categories this app version doesn't know (and app events).
  final ProtectionCategory? category;
  final EventSourceKind source;
  final double confidence;
  final String ruleType;

  /// False for non-block events (e.g. a temporary unlock).
  final bool isBlock;

  /// Raw category id (e.g. "custom", which has no [ProtectionCategory]).
  final String? categoryId;

  bool get isCustomCategory => categoryId == 'custom';
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
    this.includeSubdomains = true,
  });

  final String domain;
  final RuleAction action;

  /// Content category for blocked domains; null for allowed ones and for
  /// the user's own "custom" category.
  final ProtectionCategory? category;
  final DateTime? updatedAt;

  /// Blocks always cover subdomains; allowlist entries may be exact.
  final bool includeSubdomains;
}

enum YouTubeMode {
  off,
  moderate,
  strict;

  static YouTubeMode fromId(Object? id) =>
      values.firstWhere((v) => v.name == id, orElse: () => strict);
}

/// Search Protection settings (native side is the source of truth).
class SearchSettings {
  const SearchSettings({
    this.enabled = true,
    this.google = true,
    this.bing = true,
    this.duckDuckGo = true,
    this.youtube = YouTubeMode.strict,
  });

  final bool enabled;
  final bool google;
  final bool bing;
  final bool duckDuckGo;
  final YouTubeMode youtube;

  SearchSettings copyWith({
    bool? enabled,
    bool? google,
    bool? bing,
    bool? duckDuckGo,
    YouTubeMode? youtube,
  }) => SearchSettings(
    enabled: enabled ?? this.enabled,
    google: google ?? this.google,
    bing: bing ?? this.bing,
    duckDuckGo: duckDuckGo ?? this.duckDuckGo,
    youtube: youtube ?? this.youtube,
  );

  Map<String, Object> toMap() => {
    'enabled': enabled,
    'google': google,
    'bing': bing,
    'duckDuckGo': duckDuckGo,
    'youtube': youtube.name,
  };

  factory SearchSettings.fromMap(Map<Object?, Object?> m) => SearchSettings(
    enabled: m['enabled'] is bool ? m['enabled']! as bool : true,
    google: m['google'] is bool ? m['google']! as bool : true,
    bing: m['bing'] is bool ? m['bing']! as bool : true,
    duckDuckGo: m['duckDuckGo'] is bool ? m['duckDuckGo']! as bool : true,
    youtube: YouTubeMode.fromId(m['youtube']),
  );

  /// True if [next] loosens protection compared to this (needs the PIN).
  bool isLoosenedBy(SearchSettings next) =>
      (enabled && !next.enabled) ||
      (google && !next.google) ||
      (bing && !next.bing) ||
      (duckDuckGo && !next.duckDuckGo) ||
      next.youtube.index < youtube.index;

  @override
  bool operator ==(Object other) =>
      other is SearchSettings &&
      other.enabled == enabled &&
      other.google == google &&
      other.bing == bing &&
      other.duckDuckGo == duckDuckGo &&
      other.youtube == youtube;

  @override
  int get hashCode => Object.hash(enabled, google, bing, duckDuckGo, youtube);
}

enum SearchEngineId { google, bing, duckduckgo, youtube }

/// Outcome of a submitted search. Never contains the query.
class SearchCheck {
  const SearchCheck({
    required this.action,
    required this.category,
    required this.confidence,
    required this.ruleType,
    required this.reason,
    required this.opened,
  });

  final RuleAction action;
  final ProtectionCategory? category;
  final double confidence;
  final String ruleType;
  final String reason;

  /// Results were opened in the browser (only when allowed).
  final bool opened;

  bool get blocked => action == RuleAction.block;
}

class InstalledApp {
  const InstalledApp({required this.packageName, required this.label});

  final String packageName;
  final String label;
}

class ProtectedApp extends InstalledApp {
  const ProtectedApp({
    required super.packageName,
    required super.label,
    this.addedAt,
  });

  final DateTime? addedAt;
}

/// State of SafeGuard's App Protection accessibility service.
enum AccessibilityStatus {
  /// No native layer (tests, non-Android).
  unsupported,

  /// The device/profile doesn't allow it.
  unavailable,

  /// The user declined SafeGuard's disclosure.
  permissionDenied,
  disabled,
  enabled;

  static AccessibilityStatus fromId(Object? id) => switch (id) {
    'enabled' => enabled,
    'disabled' => disabled,
    'permission_denied' => permissionDenied,
    'unavailable' => unavailable,
    _ => unavailable,
  };
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

  /// [category] null = "custom" (the user's own category).
  Future<DomainRule> addBlockedDomain(
    String domain,
    ProtectionCategory? category,
  );

  /// Exact by default (the domain and `www.` only); [includeSubdomains]
  /// opens every subdomain too.
  Future<DomainRule> addAllowedDomain(
    String domain, {
    bool includeSubdomains = false,
  });
  Future<bool> removeRule(DomainRule rule);

  Future<List<BlockEvent>> blockedLogs({int limit = 200});
  Future<void> clearLogs();
  Future<ProtectionStats> statistics();

  /// Opens Android's VPN settings (for "Always-on VPN").
  Future<void> openVpnSettings();

  /// Stops the VPN and deletes native rules, logs and config.
  Future<void> eraseAll();

  // ---- Phase 3: Search Protection ----
  Future<SearchSettings> searchSettings();
  Future<SearchSettings> setSearchSettings(SearchSettings settings);

  /// Classifies a *submitted* query natively and opens results only if
  /// allowed. The query is not stored or logged anywhere.
  Future<SearchCheck> submitSearch(String query, SearchEngineId engine);

  // ---- Phase 3: App Protection ----
  Future<List<ProtectedApp>> protectedApps();
  Future<List<InstalledApp>> launchableApps();
  Future<ProtectedApp> addProtectedApp(String packageName);
  Future<bool> removeProtectedApp(String packageName);
  Future<AccessibilityStatus> accessibilityStatus();

  /// Records the answer to SafeGuard's disclosure; returns the new status.
  Future<AccessibilityStatus> setAccessibilityDisclosure({
    required bool accepted,
  });
  Future<void> openAccessibilitySettings();

  // ---- Phase 4: AI Protection (on-device) ----
  Future<AiSettings> aiSettings();
  Future<AiSettings> setAiSettings(AiSettings settings);
  Future<AiStatistics> aiStatistics();

  /// "Report incorrect block": stores source, category, rounded confidence
  /// and time only.
  Future<void> reportFalsePositive({
    required EventSourceKind source,
    required ProtectionCategory category,
    required double confidence,
  });

  /// Lets the user pick one image in the system picker and classifies it
  /// in memory. Nothing is stored.
  Future<ImageCheck> checkImage();

  // ---- Phase 5: advanced protection ----
  Future<HealthReport> health();
  Future<void> acknowledgeIncidents(DateTime upTo);

  /// Asks native to restart a stopped/failed VPN if its policy allows.
  Future<bool> tryRecover();

  /// Temporary unlock: 5, 10 or 30 minutes (PIN checked by the UI).
  Future<HealthReport> startPause(int minutes);
  Future<HealthReport> endPause();
  Future<HealthReport> enterSafeMode();
  Future<HealthReport> resetProtection();
  Future<DetailedStats> detailedStatistics();
  Future<List<CustomKeyword>> keywords();

  /// [category] null = "custom".
  Future<CustomKeyword> addKeyword(
    String keyword,
    ProtectionCategory? category,
  );
  Future<bool> removeKeyword(int id);

  /// Opens the system "save file" dialog for [json].
  Future<ExportResult> saveExport(String json);
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
  Future<DomainRule> addBlockedDomain(String d, ProtectionCategory? c) async =>
      DomainRule(domain: d, action: RuleAction.block, category: c);
  @override
  Future<DomainRule> addAllowedDomain(
    String d, {
    bool includeSubdomains = false,
  }) async => DomainRule(
    domain: d,
    action: RuleAction.allow,
    includeSubdomains: includeSubdomains,
  );
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
  @override
  Future<SearchSettings> searchSettings() async => const SearchSettings();
  @override
  Future<SearchSettings> setSearchSettings(SearchSettings s) async => s;
  @override
  Future<SearchCheck> submitSearch(String q, SearchEngineId e) async =>
      const SearchCheck(
        action: RuleAction.allow,
        category: null,
        confidence: 0,
        ruleType: 'keyword',
        reason: 'unsupported',
        opened: false,
      );
  @override
  Future<List<ProtectedApp>> protectedApps() async => const [];
  @override
  Future<List<InstalledApp>> launchableApps() async => const [];
  @override
  Future<ProtectedApp> addProtectedApp(String p) async =>
      ProtectedApp(packageName: p, label: p);
  @override
  Future<bool> removeProtectedApp(String p) async => false;
  @override
  Future<AccessibilityStatus> accessibilityStatus() async =>
      AccessibilityStatus.unsupported;
  @override
  Future<AccessibilityStatus> setAccessibilityDisclosure({
    required bool accepted,
  }) async => AccessibilityStatus.unsupported;
  @override
  Future<void> openAccessibilitySettings() async {}
  @override
  Future<AiSettings> aiSettings() async => const AiSettings();
  @override
  Future<AiSettings> setAiSettings(AiSettings s) async => s;
  @override
  Future<AiStatistics> aiStatistics() async => const AiStatistics();
  @override
  Future<void> reportFalsePositive({
    required EventSourceKind source,
    required ProtectionCategory category,
    required double confidence,
  }) async {}
  @override
  Future<ImageCheck> checkImage() async => const ImageCheck(
    status: ImageCheckStatus.unavailable,
    error: 'unsupported',
  );
  @override
  Future<HealthReport> health() async => HealthReport.unknown;
  @override
  Future<void> acknowledgeIncidents(DateTime upTo) async {}
  @override
  Future<bool> tryRecover() async => false;
  @override
  Future<HealthReport> startPause(int minutes) async => HealthReport.unknown;
  @override
  Future<HealthReport> endPause() async => HealthReport.unknown;
  @override
  Future<HealthReport> enterSafeMode() async => HealthReport.unknown;
  @override
  Future<HealthReport> resetProtection() async => HealthReport.unknown;
  @override
  Future<DetailedStats> detailedStatistics() async => const DetailedStats();
  @override
  Future<List<CustomKeyword>> keywords() async => const [];
  @override
  Future<CustomKeyword> addKeyword(String k, ProtectionCategory? c) async =>
      CustomKeyword(id: 0, keyword: k, category: c);
  @override
  Future<bool> removeKeyword(int id) async => false;
  @override
  Future<ExportResult> saveExport(String json) async => ExportResult.failed;
}

abstract interface class ProtectionRepository {
  Future<ProtectionState> load();
  Future<void> save(ProtectionState state);
}
