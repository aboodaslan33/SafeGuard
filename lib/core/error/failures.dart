/// Typed failures. Every repository/service returns one of these instead of
/// throwing, so the UI can decide how to present each case explicitly.
sealed class AppFailure {
  const AppFailure(this.message, {this.cause, this.stackTrace});

  /// User-facing Arabic message. Never contains technical detail.
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => '$runtimeType($message, cause: $cause)';
}

/// Reading/writing local or secure storage failed.
final class StorageFailure extends AppFailure {
  const StorageFailure({super.cause, super.stackTrace})
    : super('تعذّر حفظ البيانات على الجهاز. حاول مرة أخرى.');
}

/// Input rejected by a domain rule (e.g. weak PIN).
final class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message);
}

/// Wrong PIN. [remainingAttempts] before a temporary lockout starts.
final class PinMismatchFailure extends AppFailure {
  const PinMismatchFailure({required this.remainingAttempts})
    : super('الرمز غير صحيح');

  final int remainingAttempts;
}

/// Too many wrong attempts; PIN entry is blocked until [lockedUntil].
final class PinLockedFailure extends AppFailure {
  const PinLockedFailure({required this.lockedUntil})
    : super('محاولات كثيرة. انتظر قليلًا ثم حاول مجددًا.');

  final DateTime lockedUntil;
}

/// Stored data exists but can't be understood (corruption / tampering).
final class CorruptedDataFailure extends AppFailure {
  const CorruptedDataFailure({super.cause})
    : super('بيانات الحماية المحفوظة غير صالحة.');
}

/// Anything we did not anticipate. Logged with full detail.
final class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure({super.cause, super.stackTrace})
    : super('حدث خطأ غير متوقع.');
}

/// A failure reported by the native protection engine, keyed by the error
/// code the platform channel returns.
final class EngineFailure extends AppFailure {
  EngineFailure(this.code, {super.cause}) : super(_messages[code] ?? _fallback);

  final String code;

  static const _fallback = 'تعذّر تنفيذ العملية في محرك الحماية.';
  static const _messages = {
    'PERMISSION_REQUIRED': 'يلزم السماح لـ SafeGuard بإنشاء اتصال VPN محلي.',
    'PERMISSION_DENIED': 'لم تُمنح موافقة VPN، لذلك لا يمكن تشغيل الحماية.',
    'INVALID_DOMAIN': 'هذا ليس اسم نطاق صالحًا.',
    'INVALID_CATEGORY': 'اختر فئة للنطاق المحظور.',
    'LIMIT_REACHED': 'وصلت إلى الحد الأقصى للنطاقات المخصصة.',
    'UNSUPPORTED': 'هذا الجهاز لا يدعم تطبيقات VPN.',
    'INVALID_PACKAGE': 'اسم الحزمة غير صالح.',
    'PACKAGE_NOT_INSTALLED': 'التطبيق غير مثبت على هذا الجهاز.',
    'DUPLICATE_PACKAGE': 'هذا التطبيق محمي بالفعل.',
    'PACKAGE_NOT_ALLOWED':
        'لا يمكن حماية هذا التطبيق: يحتاجه النظام أو الاتصال أو الإعدادات.',
    'INVALID_ARGUMENT': 'المدخلات غير صالحة.',
  };
}
