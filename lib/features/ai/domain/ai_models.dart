import '../../protection/domain/protection.dart';

/// How eagerly AI results block (native `DetectionMode`).
enum DetectionMode {
  /// Blocks only high-confidence detections.
  normal,

  /// Lower thresholds: blocks more, with more false positives.
  strict,

  /// The user sets each threshold.
  custom;

  static DetectionMode fromId(Object? id) =>
      values.firstWhere((v) => v.name == id, orElse: () => normal);
}

/// AI Protection settings. Native is the source of truth; the threshold
/// profiles come from native too (these defaults are only used when no
/// native engine exists, e.g. in tests).
class AiSettings {
  const AiSettings({
    this.enabled = true,
    this.mode = DetectionMode.normal,
    this.custom = const {},
    this.profiles = defaultProfiles,
    this.customMin = 0.5,
    this.customMax = 0.99,
    this.textModelAvailable = false,
    this.imageModelAvailable = false,
    this.textModelId,
  });

  static const defaultProfiles = {
    DetectionMode.normal: {
      ProtectionCategory.sexual: 0.90,
      ProtectionCategory.violence: 0.90,
      ProtectionCategory.gore: 0.85,
      ProtectionCategory.gambling: 0.90,
      ProtectionCategory.drugs: 0.90,
      ProtectionCategory.dangerous: 0.90,
    },
    DetectionMode.strict: {
      ProtectionCategory.sexual: 0.70,
      ProtectionCategory.violence: 0.75,
      ProtectionCategory.gore: 0.65,
      ProtectionCategory.gambling: 0.70,
      ProtectionCategory.drugs: 0.70,
      ProtectionCategory.dangerous: 0.75,
    },
  };

  final bool enabled;
  final DetectionMode mode;

  /// CUSTOM thresholds; missing categories use NORMAL.
  final Map<ProtectionCategory, double> custom;
  final Map<DetectionMode, Map<ProtectionCategory, double>> profiles;
  final double customMin;
  final double customMax;
  final bool textModelAvailable;
  final bool imageModelAvailable;
  final String? textModelId;

  double _normal(ProtectionCategory c) =>
      profiles[DetectionMode.normal]?[c] ?? 1.0;

  double clampCustom(double v) =>
      v.isNaN ? customMax : (v.clamp(customMin, customMax) * 100).round() / 100;

  /// The threshold in force for [c] under [mode].
  double threshold(ProtectionCategory c) => switch (mode) {
    DetectionMode.normal => _normal(c),
    DetectionMode.strict => profiles[DetectionMode.strict]?[c] ?? _normal(c),
    DetectionMode.custom =>
      custom[c] == null ? _normal(c) : clampCustom(custom[c]!),
  };

  /// True if [next] blocks less than this anywhere (needs the PIN).
  bool isLoosenedBy(AiSettings next) {
    if (enabled && !next.enabled) return true;
    return ProtectionCategory.networkFiltered.any(
      (c) => next.threshold(c) > threshold(c) + 1e-9,
    );
  }

  AiSettings copyWith({
    bool? enabled,
    DetectionMode? mode,
    Map<ProtectionCategory, double>? custom,
  }) => AiSettings(
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    custom: custom ?? this.custom,
    profiles: profiles,
    customMin: customMin,
    customMax: customMax,
    textModelAvailable: textModelAvailable,
    imageModelAvailable: imageModelAvailable,
    textModelId: textModelId,
  );

  Map<String, Object> toMap() => {
    'enabled': enabled,
    'mode': mode.name,
    'custom': {for (final e in custom.entries) e.key.id: e.value},
  };

  /// Defensive: anything malformed falls back to the protective default.
  factory AiSettings.fromMap(Map<Object?, Object?> m) {
    Map<ProtectionCategory, double> cats(Object? raw) {
      final out = <ProtectionCategory, double>{};
      if (raw is Map) {
        raw.forEach((k, v) {
          final c = k is String ? ProtectionCategory.fromId(k) : null;
          if (c != null && c.isNetworkFiltered && v is num) {
            out[c] = v.toDouble();
          }
        });
      }
      return out;
    }

    final rawProfiles = m['profiles'];
    final profiles = <DetectionMode, Map<ProtectionCategory, double>>{
      ...defaultProfiles,
    };
    if (rawProfiles is Map) {
      for (final mode in [DetectionMode.normal, DetectionMode.strict]) {
        // Native values override; categories it omits keep the defaults.
        profiles[mode] = {
          ...defaultProfiles[mode]!,
          ...cats(rawProfiles[mode.name]),
        };
      }
    }
    final range = m['customRange'];
    final models = m['models'];
    final text = models is Map ? models['text'] : null;
    final image = models is Map ? models['image'] : null;
    return AiSettings(
      enabled: m['enabled'] is bool ? m['enabled']! as bool : true,
      mode: DetectionMode.fromId(m['mode']),
      custom: cats(m['custom']),
      profiles: profiles,
      customMin: range is List && range.length == 2 && range[0] is num
          ? (range[0] as num).toDouble()
          : 0.5,
      customMax: range is List && range.length == 2 && range[1] is num
          ? (range[1] as num).toDouble()
          : 0.99,
      textModelAvailable: text is Map && text['available'] == true,
      imageModelAvailable: image is Map && image['available'] == true,
      textModelId: text is Map && text['id'] is String
          ? text['id'] as String
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiSettings &&
      other.enabled == enabled &&
      other.mode == mode &&
      _sameMap(other.custom, custom);

  @override
  int get hashCode => Object.hash(
    enabled,
    mode,
    Object.hashAllUnordered(custom.entries.map((e) => (e.key, e.value))),
  );

  static bool _sameMap(Map<Object, double> a, Map<Object, double> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

/// Aggregate counters only — never content.
class AiStatistics {
  const AiStatistics({
    this.detections = 0,
    this.blocks = 0,
    this.falsePositiveReports = 0,
    this.detectionsByCategory = const {},
    this.blocksByCategory = const {},
    this.reportsByCategory = const {},
  });

  final int detections;
  final int blocks;
  final int falsePositiveReports;
  final Map<ProtectionCategory, int> detectionsByCategory;
  final Map<ProtectionCategory, int> blocksByCategory;
  final Map<ProtectionCategory, int> reportsByCategory;

  factory AiStatistics.fromMap(Map<Object?, Object?> m) {
    int n(Object? v) => v is num ? v.toInt() : 0;
    Map<ProtectionCategory, int> byCat(Object? raw) => {
      if (raw is Map)
        for (final e in raw.entries)
          if (e.key is String &&
              ProtectionCategory.fromId(e.key as String) != null)
            ProtectionCategory.fromId(e.key as String)!: n(e.value),
    };
    return AiStatistics(
      detections: n(m['detections']),
      blocks: n(m['blocks']),
      falsePositiveReports: n(m['falsePositiveReports']),
      detectionsByCategory: byCat(m['detectionsByCategory']),
      blocksByCategory: byCat(m['blocksByCategory']),
      reportsByCategory: byCat(m['reportsByCategory']),
    );
  }
}

enum ContentVerdict { allow, block, unknown }

enum ImageCheckStatus { ok, uncertain, unavailable, rejected, cancelled }

/// Result of "check an image". The image itself never reaches Flutter.
class ImageCheck {
  const ImageCheck({
    required this.status,
    this.error,
    this.verdict = ContentVerdict.unknown,
    this.category,
    this.confidence = 0,
    this.reason = '',
    this.scores = const {},
    this.modelId,
  });

  final ImageCheckStatus status;

  /// Native error id (e.g. `no_model`, `unsupported_type`, `file_too_large`).
  final String? error;
  final ContentVerdict verdict;
  final ProtectionCategory? category;
  final double confidence;
  final String reason;
  final Map<ProtectionCategory, double> scores;
  final String? modelId;

  factory ImageCheck.fromMap(Map<Object?, Object?> m) {
    final status = ImageCheckStatus.values.firstWhere(
      (s) => s.name == m['status'],
      orElse: () => ImageCheckStatus.unavailable,
    );
    final rawScores = m['scores'];
    return ImageCheck(
      status: status,
      error: m['error'] as String?,
      verdict: ContentVerdict.values.firstWhere(
        (v) => v.name == m['action'],
        orElse: () => ContentVerdict.unknown,
      ),
      category: m['category'] is String
          ? ProtectionCategory.fromId(m['category']! as String)
          : null,
      confidence: m['confidence'] is num
          ? (m['confidence']! as num).toDouble()
          : 0,
      reason: m['reason'] as String? ?? '',
      scores: {
        if (rawScores is Map)
          for (final e in rawScores.entries)
            if (e.key is String &&
                ProtectionCategory.fromId(e.key as String) != null &&
                e.value is num)
              ProtectionCategory.fromId(e.key as String)!: (e.value as num)
                  .toDouble(),
      },
      modelId: m['modelId'] as String?,
    );
  }
}
