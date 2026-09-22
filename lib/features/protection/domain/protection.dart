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

  static ProtectionCategory? fromId(String id) {
    for (final c in values) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// The user's protection policy. This is *intent*: what should be blocked.
/// Whether it is actually enforced depends on [EngineStatus].
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

/// Whether a filtering engine is present and enforcing the policy.
enum EngineStatus {
  /// No enforcement layer is installed in this build (Phase 1).
  notInstalled,

  /// Installed but not running (e.g. VPN permission not granted).
  stopped,

  /// Running and filtering.
  running,
}

/// Seam for the enforcement layer. Phase 2 plugs the Android VpnService /
/// DNS filter in here via a platform channel; nothing else changes.
abstract interface class ProtectionEngine {
  Future<EngineStatus> status();
  Future<void> apply(ProtectionState state);
}

/// Phase 1 engine: stores nothing, enforces nothing, and says so.
class UnavailableProtectionEngine implements ProtectionEngine {
  const UnavailableProtectionEngine();

  @override
  Future<EngineStatus> status() async => EngineStatus.notInstalled;

  @override
  Future<void> apply(ProtectionState state) async {}
}

/// Blocking statistics. All null until an engine produces real data —
/// the UI shows a placeholder rather than invented numbers.
class ProtectionStats {
  const ProtectionStats({this.today, this.thisWeek, this.total});

  static const unavailable = ProtectionStats();

  final int? today;
  final int? thisWeek;
  final int? total;

  bool get isAvailable => today != null;
}

abstract interface class ProtectionRepository {
  Future<ProtectionState> load();
  Future<void> save(ProtectionState state);
}
