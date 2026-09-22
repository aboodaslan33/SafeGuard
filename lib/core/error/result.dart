import 'app_logger.dart';
import 'failures.dart';

/// Minimal result type: either [Ok] with a value or [Err] with an
/// [AppFailure]. Use Dart pattern matching to consume it.
sealed class Result<T> {
  const Result();

  bool get isOk => this is Ok<T>;

  T? get valueOrNull => switch (this) {
    Ok(:final value) => value,
    Err() => null,
  };

  AppFailure? get failureOrNull => switch (this) {
    Ok() => null,
    Err(:final failure) => failure,
  };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.failure);
  final AppFailure failure;
}

/// Runs [body] and converts thrown errors into a typed [Err].
///
/// [AppFailure]s thrown deliberately pass through untouched; anything else is
/// mapped by [onError] (defaults to [UnexpectedFailure]) and logged.
Future<Result<T>> guard<T>(
  Future<T> Function() body, {
  AppFailure Function(Object error, StackTrace stack)? onError,
}) async {
  try {
    return Ok(await body());
  } on AppFailure catch (f) {
    return Err(f);
  } catch (error, stack) {
    final failure =
        onError?.call(error, stack) ??
        UnexpectedFailure(cause: error, stackTrace: stack);
    AppLogger.error('guard', error, stack);
    return Err(failure);
  }
}
