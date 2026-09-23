import 'dart:convert';

import '../storage/stores.dart';

/// One crash, reduced to what helps fix it and nothing that identifies the
/// user: the error *type* (never its message, which can contain URLs,
/// queries or tokens) and the app's own stack frames (file:line).
class CrashRecord {
  const CrashRecord({
    required this.time,
    required this.errorType,
    required this.frames,
    required this.appVersion,
    this.androidVersion,
    this.deviceModel,
  });

  final DateTime time;
  final String errorType;
  final List<String> frames;
  final String appVersion;
  final String? androidVersion;
  final String? deviceModel;

  Map<String, Object?> toJson() => {
    't': time.millisecondsSinceEpoch,
    'type': errorType,
    'frames': frames,
    'app': appVersion,
    if (androidVersion != null) 'android': androidVersion,
    if (deviceModel != null) 'model': deviceModel,
  };

  static CrashRecord? fromJson(Object? j) {
    if (j is! Map || j['t'] is! int || j['type'] is! String) return null;
    return CrashRecord(
      time: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
      errorType: j['type'] as String,
      frames: [
        if (j['frames'] is List)
          for (final f in j['frames'] as List)
            if (f is String) f,
      ],
      appVersion: '${j['app'] ?? '?'}',
      androidVersion: j['android'] as String?,
      deviceModel: j['model'] as String?,
    );
  }

  String toText() => [
    '${time.toUtc().toIso8601String()} $errorType',
    'app $appVersion'
        '${androidVersion == null ? '' : ' · Android $androidVersion'}'
        '${deviceModel == null ? '' : ' · $deviceModel'}',
    ...frames.map((f) => '  at $f'),
  ].join('\n');
}

/// Reduces errors and stack traces to non-sensitive tokens.
abstract final class CrashSanitizer {
  static final _typeToken = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$<>, ]{0,80}$');

  /// `#3  Foo.bar (package:safeguard/x/y.dart:12:5)` → `Foo.bar (x/y.dart:12)`.
  /// Frames outside the app's own package are dropped (they add nothing we
  /// can fix and may carry framework details).
  static final _frame = RegExp(
    r'^#\d+\s+(\S[^(]*?)\s+\(package:safeguard/([A-Za-z0-9_/]+\.dart):(\d+)(?::\d+)?\)$',
  );

  static String errorType(Object error) {
    final t = error.runtimeType.toString();
    return _typeToken.hasMatch(t) ? t : 'Error';
  }

  static List<String> frames(StackTrace? stack, {int max = 12}) {
    if (stack == null) return const [];
    final out = <String>[];
    for (final line in stack.toString().split('\n')) {
      final m = _frame.firstMatch(line.trim());
      if (m == null) continue;
      final symbol = m.group(1)!.replaceAll(RegExp(r'[^A-Za-z0-9_.<>]'), '');
      out.add('$symbol (${m.group(2)}:${m.group(3)})');
      if (out.length >= max) break;
    }
    return out;
  }
}

/// Crash-reporting abstraction. SafeGuard ships only the local
/// implementation: reports stay on the device, the user can view, copy
/// and delete them, and can turn recording off. A remote transport could
/// be added behind this interface later — opt-in, disclosed, and sending
/// only [CrashRecord] fields.
abstract interface class CrashReporter {
  bool get enabled;
  Future<void> setEnabled(bool enabled);
  Future<void> record(Object error, StackTrace? stack);
  Future<List<CrashRecord>> reports();
  Future<void> clear();
}

class LocalCrashReporter implements CrashReporter {
  LocalCrashReporter(
    this._store, {
    required this.appVersion,
    this.androidVersion,
    this.deviceModel,
    this.maxReports = 10,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final KeyValueStore _store;
  final String appVersion;
  String? androidVersion;
  String? deviceModel;
  final int maxReports;
  final DateTime Function() _clock;

  static const _keyReports = 'crash.reports';
  static const _keyEnabled = 'crash.enabled';

  bool _enabled = true;
  @override
  bool get enabled => _enabled;

  Future<void> load() async {
    _enabled = await _store.read(_keyEnabled) != 'false';
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _store.write(_keyEnabled, '$enabled');
    if (!enabled) await clear();
  }

  /// Serialises read-modify-write so concurrent crashes aren't lost.
  Future<void> _queue = Future.value();

  @override
  Future<void> record(Object error, StackTrace? stack) {
    if (!_enabled) return Future.value();
    return _queue = _queue.then((_) => _record(error, stack));
  }

  Future<void> _record(Object error, StackTrace? stack) async {
    try {
      final list = await reports();
      list.insert(
        0,
        CrashRecord(
          time: _clock(),
          errorType: CrashSanitizer.errorType(error),
          frames: CrashSanitizer.frames(stack),
          appVersion: appVersion,
          androidVersion: androidVersion,
          deviceModel: deviceModel,
        ),
      );
      await _store.write(
        _keyReports,
        jsonEncode([for (final r in list.take(maxReports)) r.toJson()]),
      );
    } catch (_) {
      // Recording a crash must never cause another one.
    }
  }

  @override
  Future<List<CrashRecord>> reports() async {
    final raw = await _store.read(_keyReports);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw);
      return [
        if (list is List)
          for (final j in list) ?CrashRecord.fromJson(j),
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> clear() => _store.delete(_keyReports);
}
