import '../i18n/i18n.dart';

/// Small formatting helpers (no intl dependency needed for these). Arabic
/// has singular/dual/plural agreement; English uses plain plurals.
abstract final class ArabicFormat {
  /// "الآن", "قبل 5 دقائق", "قبل ساعتين" / "just now", "5 minutes ago".
  static String relative(DateTime time, {DateTime? now}) {
    final diff = (now ?? DateTime.now()).difference(time);
    if (diff.inMinutes < 1) return tr('الآن', 'just now');
    if (diff.inHours < 1) {
      return tr(
        'قبل ${count(diff.inMinutes, 'دقيقة', 'دقيقتين', 'دقائق')}',
        '${_en(diff.inMinutes, 'minute')} ago',
      );
    }
    if (diff.inDays < 1) {
      return tr(
        'قبل ${count(diff.inHours, 'ساعة', 'ساعتين', 'ساعات')}',
        '${_en(diff.inHours, 'hour')} ago',
      );
    }
    return tr(
      'قبل ${count(diff.inDays, 'يوم', 'يومين', 'أيام')}',
      '${_en(diff.inDays, 'day')} ago',
    );
  }

  /// Arabic number agreement: 1 → singular, 2 → dual, 3–10 → plural,
  /// 11+ → singular with the number.
  static String count(int n, String one, String two, String few) {
    if (n == 1) return one;
    if (n == 2) return two;
    if (n >= 3 && n <= 10) return '$n $few';
    return '$n $one';
  }

  static String _en(int n, String unit) => n == 1 ? '1 $unit' : '$n ${unit}s';
}
