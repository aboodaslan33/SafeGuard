/// Injectable time source so lockout and timestamps are testable.
typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now();
