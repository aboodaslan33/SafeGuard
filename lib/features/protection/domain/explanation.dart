import '../../../core/i18n/i18n.dart';

/// Why SafeGuard blocked or allowed something — one code per decision,
/// mirroring native `engine/explain/Explanation` (ids must match).
/// Deliberately coarse: no model internals, no matched text.
enum DecisionExplanation {
  protectionOff('protection_off', false),
  invalidRequest('invalid_request', false),
  userAllowed('user_allowed', false),
  userBlockedDomain('user_blocked_domain', true),
  knownBlockedDomain('known_blocked_domain', true),
  knownSafeDomain('known_safe_domain', false),
  categoryDisabled('category_disabled', false),
  classifiedDomain('classified_domain', true),
  strictUnknownDomain('strict_unknown_domain', true),
  noMatch('no_match', false),
  customKeyword('custom_keyword', true),
  searchRule('search_rule', true),
  searchBelowThreshold('search_below_threshold', false),
  aiAboveThreshold('ai_above_threshold', true),
  aiBelowThreshold('ai_below_threshold', false),
  aiUncertain('ai_uncertain', false),
  aiUnavailable('ai_unavailable', false),
  aiSafe('ai_safe', false),
  protectedApp('protected_app', true),
  temporaryUnlock('temporary_unlock', false);

  const DecisionExplanation(this.id, this.blocks);
  final String id;
  final bool blocks;

  static DecisionExplanation? fromId(Object? id) {
    for (final e in values) {
      if (e.id == id) return e;
    }
    return null;
  }

  String get verdictLabel =>
      blocks ? tr('محظور', 'BLOCKED') : tr('مسموح', 'ALLOWED');

  String get reason => switch (this) {
    protectionOff => tr('الحماية متوقفة', 'Protection is off'),
    invalidRequest => tr('طلب غير صالح', 'Invalid request'),
    userAllowed => tr('نطاق في قائمة السماح', 'Domain in your allowlist'),
    userBlockedDomain => tr('نطاق حظرته بنفسك', 'Domain you blocked yourself'),
    knownBlockedDomain => tr(
      'نطاق معروف ضمن فئة محظورة',
      'Known domain in a blocked category',
    ),
    knownSafeDomain => tr('نطاق معروف بأنه آمن', 'Known safe domain'),
    categoryDisabled => tr('الفئة غير مفعّلة', 'Category is turned off'),
    classifiedDomain => tr(
      'اسم النطاق يطابق فئة محظورة',
      'Domain name matches a blocked category',
    ),
    strictUnknownDomain => tr(
      'نطاق غير معروف في الوضع الصارم',
      'Unknown domain in strict mode',
    ),
    noMatch => tr('لا توجد قاعدة مطابقة', 'No matching rule'),
    customKeyword => tr('كلمة محظورة أضفتها', 'A blocked keyword you added'),
    searchRule => tr(
      'قاعدة بحث ضمن فئة محظورة',
      'Search rule in a blocked category',
    ),
    searchBelowThreshold => tr(
      'تطابق ضعيف مع قواعد البحث (تحت الحد)',
      'Weak match with search rules (below threshold)',
    ),
    aiAboveThreshold => tr(
      'ثقة التصنيف الذكي تجاوزت الحد المضبوط',
      'AI classification confidence exceeded the configured threshold',
    ),
    aiBelowThreshold => tr(
      'ثقة التصنيف الذكي تحت الحد',
      'AI confidence below the threshold',
    ),
    aiUncertain => tr(
      'التصنيف الذكي غير متأكد؛ لا يُحظر',
      'AI was uncertain; not blocked',
    ),
    aiUnavailable => tr(
      'التصنيف الذكي غير متاح؛ طُبقت القواعد فقط',
      'AI unavailable; rules only were applied',
    ),
    aiSafe => tr('صُنّف كمحتوى آمن', 'Classified as safe'),
    protectedApp => tr('تطبيق محمي', 'Protected app'),
    temporaryUnlock => tr('إيقاف مؤقت للحماية', 'Temporary pause'),
  };
}

/// One traced decision: what decided and why, never what was requested.
class TraceEntry {
  const TraceEntry({
    required this.time,
    required this.sourceId,
    required this.explanation,
    required this.categoryId,
    this.confidenceBucket,
    this.stages = const [],
  });

  final DateTime time;
  final String sourceId;
  final DecisionExplanation explanation;
  final String categoryId;

  /// Confidence rounded down to 10 % steps, for AI decisions only.
  final int? confidenceBucket;

  /// Pipeline stages evaluated, in order, up to the deciding one.
  final List<String> stages;
}

class DecisionTraceSnapshot {
  const DecisionTraceSnapshot({this.enabled = false, this.entries = const []});
  final bool enabled;
  final List<TraceEntry> entries;

  static DecisionTraceSnapshot fromMap(Map<Object?, Object?> m) {
    final raw = m['entries'];
    return DecisionTraceSnapshot(
      enabled: m['enabled'] == true,
      entries: [
        if (raw is List)
          for (final e in raw.whereType<Map<Object?, Object?>>())
            if (e['timestamp'] is int &&
                DecisionExplanation.fromId(e['explanation']) != null)
              TraceEntry(
                time: DateTime.fromMillisecondsSinceEpoch(
                  e['timestamp']! as int,
                ),
                sourceId: '${e['source']}',
                explanation: DecisionExplanation.fromId(e['explanation'])!,
                categoryId: '${e['category']}',
                confidenceBucket: e['confidenceBucket'] is int
                    ? e['confidenceBucket']! as int
                    : null,
                stages: [
                  if (e['stages'] is List)
                    for (final s in e['stages']! as List)
                      if (s is String) s,
                ],
              ),
      ],
    );
  }
}
