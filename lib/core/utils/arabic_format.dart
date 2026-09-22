/// Small Arabic formatting helpers (no intl dependency needed for these).
abstract final class ArabicFormat {
  /// "الآن", "قبل 5 دقائق", "قبل ساعتين", "قبل 3 أيام".
  static String relative(DateTime time, {DateTime? now}) {
    final diff = (now ?? DateTime.now()).difference(time);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inHours < 1) {
      return 'قبل ${count(diff.inMinutes, 'دقيقة', 'دقيقتين', 'دقائق')}';
    }
    if (diff.inDays < 1) {
      return 'قبل ${count(diff.inHours, 'ساعة', 'ساعتين', 'ساعات')}';
    }
    return 'قبل ${count(diff.inDays, 'يوم', 'يومين', 'أيام')}';
  }

  /// Arabic number agreement: 1 → singular, 2 → dual, 3–10 → plural,
  /// 11+ → singular with the number.
  static String count(int n, String one, String two, String few) {
    if (n == 1) return one;
    if (n == 2) return two;
    if (n >= 3 && n <= 10) return '$n $few';
    return '$n $one';
  }
}
