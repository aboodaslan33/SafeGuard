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
