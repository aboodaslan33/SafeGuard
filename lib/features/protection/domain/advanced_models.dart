import 'protection.dart';

/// Global protection mode (native `ProtectionMode`).
enum ProtectionMode {
  /// Blocks on high confidence; fewer false positives.
  normal,

  /// Everything on, stricter thresholds.
  strict,

  /// The user's own categories, thresholds, search and AI settings.
  custom;

  /// Missing/unknown → custom, so settings saved before modes existed keep
  /// working exactly as before.
  static ProtectionMode fromId(Object? id) =>
      values.firstWhere((v) => v.name == id, orElse: () => custom);

  /// Presets force every category, search protection and AI on.
  bool get isPreset => this != custom;

  /// Every change needs the PIN except NORMAL → STRICT.
  static bool changeNeedsPin(ProtectionMode from, ProtectionMode to) =>
      from != to && !(from == normal && to == strict);
}

enum OverallHealth {
  protected,
  partiallyProtected,
  notProtected,

  /// No native engine (tests, non-Android).
  unknown;

  static OverallHealth fromId(Object? id) => switch (id) {
    'protected' => protected,
    'partially_protected' => partiallyProtected,
    'not_protected' => notProtected,
    _ => unknown,
  };
}

enum LayerState {
  active,
  degraded,
  inactive,
  off,
  notConfigured;

  static LayerState fromId(Object? id) => switch (id) {
    'active' => active,
    'degraded' => degraded,
    'off' => off,
    'not_configured' => notConfigured,
    _ => inactive,
  };
}

enum HealthLayer {
  vpn,
  dns,
  rules,
  search,
  ai,
  apps,
  database,
  permissions;

  static HealthLayer? fromId(Object? id) {
    for (final l in values) {
      if (l.name == id) return l;
    }
    return null;
  }
}

class LayerHealth {
  const LayerHealth(this.layer, this.state, [this.reason]);

  final HealthLayer layer;
  final LayerState state;

  /// Stable reason id from native (translated by the UI).
  final String? reason;
}

enum IncidentKind {
  vpnRevoked('vpn_revoked'),
  vpnFailed('vpn_failed'),
  permissionRevoked('permission_revoked'),
  accessibilityDisabled('accessibility_disabled'),
  bootStartFailed('boot_start_failed'),
  recovered('recovered');

  const IncidentKind(this.id);
  final String id;

  static IncidentKind? fromId(Object? id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

class ProtectionIncident {
  const ProtectionIncident(this.time, this.kind);

  final DateTime time;
  final IncidentKind kind;
}

/// Native health report plus mode, pause, Safe Mode and interruptions.
class HealthReport {
  const HealthReport({
    required this.overall,
    this.reason,
    this.layers = const [],
    this.mode = ProtectionMode.custom,
    this.pausedRemaining = Duration.zero,
    this.safeMode = false,
    this.incidents = const [],
    this.lastBootResult,
  });

  static const unknown = HealthReport(overall: OverallHealth.unknown);

  final OverallHealth overall;
  final String? reason;
  final List<LayerHealth> layers;
  final ProtectionMode mode;
  final Duration pausedRemaining;
  final bool safeMode;

  /// Unacknowledged interruptions, oldest first.
  final List<ProtectionIncident> incidents;
  final String? lastBootResult;

  bool get paused => pausedRemaining > Duration.zero;

  LayerHealth? layer(HealthLayer l) {
    for (final x in layers) {
      if (x.layer == l) return x;
    }
    return null;
  }

  /// Anything wrong the user didn't cause and should act on.
  bool get interrupted => incidents.isNotEmpty;

  factory HealthReport.fromMap(Map<Object?, Object?> m) {
    final rawLayers = m['layers'];
    final rawIncidents = m['incidents'];
    final boot = m['lastBoot'];
    final pausedMs = m['pausedRemainingMs'];
    return HealthReport(
      overall: OverallHealth.fromId(m['overall']),
      reason: m['reason'] as String?,
      layers: [
        if (rawLayers is List)
          for (final l in rawLayers.whereType<Map<Object?, Object?>>())
            if (HealthLayer.fromId(l['layer']) != null)
              LayerHealth(
                HealthLayer.fromId(l['layer'])!,
                LayerState.fromId(l['state']),
                l['reason'] as String?,
              ),
      ],
      mode: ProtectionMode.fromId(m['mode']),
      pausedRemaining: Duration(
        milliseconds: pausedMs is num ? pausedMs.toInt().clamp(0, 1800000) : 0,
      ),
      safeMode: m['safeMode'] == true,
      incidents: [
        if (rawIncidents is List)
          for (final i in rawIncidents.whereType<Map<Object?, Object?>>())
            if (IncidentKind.fromId(i['kind']) != null && i['timestamp'] is int)
              ProtectionIncident(
                DateTime.fromMillisecondsSinceEpoch(i['timestamp']! as int),
                IncidentKind.fromId(i['kind'])!,
              ),
      ],
      lastBootResult: boot is Map ? boot['result'] as String? : null,
    );
  }
}

/// Blocks in one period. Counts only.
class WindowStats {
  const WindowStats({
    this.total = 0,
    this.bySource = const {},
    this.byCategory = const {},
    this.customCategoryCount = 0,
    this.falsePositiveReports = 0,
  });

  final int total;
  final Map<EventSourceKind, int> bySource;
  final Map<ProtectionCategory, int> byCategory;

  /// Blocks by the user's own domains/keywords (category "custom").
  final int customCategoryCount;
  final int falsePositiveReports;

  int source(EventSourceKind s) => bySource[s] ?? 0;

  factory WindowStats.fromMap(Object? raw) {
    if (raw is! Map) return const WindowStats();
    int n(Object? v) => v is num ? v.toInt() : 0;
    final src = raw['bySource'];
    final cat = raw['byCategory'];
    return WindowStats(
      total: n(raw['total']),
      bySource: {
        if (src is Map)
          for (final e in src.entries)
            for (final s in EventSourceKind.values)
              if (s.name == e.key) s: n(e.value),
      },
      byCategory: {
        if (cat is Map)
          for (final e in cat.entries)
            if (e.key is String &&
                ProtectionCategory.fromId(e.key as String) != null)
              ProtectionCategory.fromId(e.key as String)!: n(e.value),
      },
      customCategoryCount: cat is Map ? n(cat['custom']) : 0,
      falsePositiveReports: n(raw['falsePositiveReports']),
    );
  }
}

class DetailedStats {
  const DetailedStats({
    this.today = const WindowStats(),
    this.last7Days = const WindowStats(),
    this.last30Days = const WindowStats(),
  });

  final WindowStats today;
  final WindowStats last7Days;
  final WindowStats last30Days;

  factory DetailedStats.fromMap(Map<Object?, Object?> m) => DetailedStats(
    today: WindowStats.fromMap(m['today']),
    last7Days: WindowStats.fromMap(m['last7Days']),
    last30Days: WindowStats.fromMap(m['last30Days']),
  );
}

class CustomKeyword {
  const CustomKeyword({
    required this.id,
    required this.keyword,
    this.category,
    this.addedAt,
  });

  final int id;

  /// Normalised by native (lowercase, unified Arabic letters).
  final String keyword;

  /// Null = "custom" (the user's own category).
  final ProtectionCategory? category;
  final DateTime? addedAt;

  static CustomKeyword? fromMap(Map<Object?, Object?> m) {
    final id = m['id'];
    final k = m['keyword'];
    if (id is! int || k is! String) return null;
    final c = m['category'];
    final at = m['addedAt'];
    return CustomKeyword(
      id: id,
      keyword: k,
      category: c is String ? ProtectionCategory.fromId(c) : null,
      addedAt: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
  }
}

/// Outcome of "Export settings".
enum ExportResult { saved, cancelled, failed }

/// "Protection stopped / degraded" alerts (Phase 8).
class AlertsState {
  const AlertsState({
    this.enabled = true,
    this.permission = false,
    this.runtimePermission = true,
  });

  /// The user wants alerts (on by default).
  final bool enabled;

  /// Android allows SafeGuard to post notifications.
  final bool permission;

  /// Android 13+: permission is asked at runtime.
  final bool runtimePermission;

  bool get active => enabled && permission;

  static AlertsState fromMap(Map<Object?, Object?> m) => AlertsState(
    enabled: m['enabled'] != false,
    permission: m['permission'] == true,
    runtimePermission: m['runtimePermission'] != false,
  );
}
