import '../i18n/i18n.dart';

/// Typed failures. Every repository/service returns one of these instead of
/// throwing, so the UI can decide how to present each case explicitly.
sealed class AppFailure {
  const AppFailure({this.cause, this.stackTrace});

  /// User-facing message in the current UI language. Never contains
  /// technical detail. A getter, so a language change applies to failures
  /// created earlier too.
  String get message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => '$runtimeType($message, cause: $cause)';
}

/// Reading/writing local or secure storage failed.
final class StorageFailure extends AppFailure {
  const StorageFailure({super.cause, super.stackTrace});

  @override
  String get message => tr(
    'تعذّر حفظ البيانات على الجهاز. حاول مرة أخرى.',
    "Couldn't save data on this device. Please try again.",
  );
}

/// Input rejected by a domain rule (e.g. weak PIN).
final class ValidationFailure extends AppFailure {
  const ValidationFailure(this.message);

  @override
  final String message;
}

/// Wrong PIN. [remainingAttempts] before a temporary lockout starts.
final class PinMismatchFailure extends AppFailure {
  const PinMismatchFailure({required this.remainingAttempts});

  @override
  String get message => tr('الرمز غير صحيح', 'Incorrect PIN');

  final int remainingAttempts;
}

/// Too many wrong attempts; PIN entry is blocked until [lockedUntil].
final class PinLockedFailure extends AppFailure {
  const PinLockedFailure({required this.lockedUntil});

  @override
  String get message => tr(
    'محاولات كثيرة. انتظر قليلًا ثم حاول مجددًا.',
    'Too many attempts. Wait a moment, then try again.',
  );

  final DateTime lockedUntil;
}

/// Stored data exists but can't be understood (corruption / tampering).
final class CorruptedDataFailure extends AppFailure {
  const CorruptedDataFailure({super.cause});

  @override
  String get message => tr(
    'بيانات الحماية المحفوظة غير صالحة.',
    'Saved protection data is invalid.',
  );
}

/// Anything we did not anticipate. Logged with full detail.
final class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure({super.cause, super.stackTrace});

  @override
  String get message =>
      tr('حدث خطأ غير متوقع.', 'An unexpected error occurred.');
}

/// A failure reported by the native protection engine, keyed by the error
/// code the platform channel returns.
final class EngineFailure extends AppFailure {
  const EngineFailure(this.code, {super.cause});

  final String code;

  @override
  String get message => _messages[code] ?? _fallback;

  static String get _fallback => tr(
    'تعذّر تنفيذ العملية في محرك الحماية.',
    "The protection engine couldn't complete the operation.",
  );
  static Map<String, String> get _messages => {
    'PERMISSION_REQUIRED': tr(
      'يلزم السماح لـ SafeGuard بإنشاء اتصال VPN محلي.',
      'SafeGuard needs permission to create a local VPN connection.',
    ),
    'PERMISSION_DENIED': tr(
      'لم تُمنح موافقة VPN، لذلك لا يمكن تشغيل الحماية.',
      "VPN consent wasn't granted, so protection can't start.",
    ),
    'INVALID_DOMAIN': tr(
      'هذا ليس اسم نطاق صالحًا.',
      "This isn't a valid domain name.",
    ),
    'INVALID_CATEGORY': tr(
      'اختر فئة للنطاق المحظور.',
      'Choose a category for the blocked domain.',
    ),
    'LIMIT_REACHED': tr(
      'وصلت إلى الحد الأقصى المسموح لهذه القائمة.',
      "You've reached the maximum size for this list.",
    ),
    'UNSUPPORTED': tr(
      'هذا الجهاز لا يدعم تطبيقات VPN.',
      "This device doesn't support VPN apps.",
    ),
    'INVALID_PACKAGE': tr('اسم الحزمة غير صالح.', 'Invalid package name.'),
    'PACKAGE_NOT_INSTALLED': tr(
      'التطبيق غير مثبت على هذا الجهاز.',
      "This app isn't installed on this device.",
    ),
    'DUPLICATE_PACKAGE': tr(
      'هذا التطبيق محمي بالفعل.',
      'This app is already protected.',
    ),
    'PACKAGE_NOT_ALLOWED': tr(
      'لا يمكن حماية هذا التطبيق: يحتاجه النظام أو الاتصال أو الإعدادات.',
      "This app can't be protected: the system, calls or settings depend on it.",
    ),
    'INVALID_ARGUMENT': tr('المدخلات غير صالحة.', 'Invalid input.'),
    'DUPLICATE_DOMAIN': tr(
      'هذا النطاق موجود في القائمة بالفعل.',
      'This domain is already in the list.',
    ),
    'IN_OTHER_LIST': tr(
      'هذا النطاق موجود في القائمة الأخرى. احذفه منها أولًا إذا أردت نقله.',
      'This domain is in the other list. Remove it there first if you want to move it.',
    ),
    'INVALID_KEYWORD': tr(
      'كلمة غير صالحة: استخدم كلمة أو عبارة من 5 كلمات كحد أقصى، دون أرقام فقط.',
      'Invalid keyword: use a word or phrase of up to 5 words, not just numbers.',
    ),
    'KEYWORD_TOO_SHORT': tr(
      'الكلمة قصيرة جدًا (3 أحرف على الأقل) لتجنّب حظر كلمات سليمة.',
      'The keyword is too short (at least 3 letters) to avoid blocking harmless words.',
    ),
    'DUPLICATE_KEYWORD': tr(
      'هذه الكلمة موجودة بالفعل.',
      'This keyword already exists.',
    ),
    'BUSY': tr(
      'هناك عملية مماثلة قيد التنفيذ.',
      'A similar operation is already in progress.',
    ),
  };
}
