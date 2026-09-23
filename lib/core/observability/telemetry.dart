import 'dart:convert';

import '../storage/stores.dart';

/// The only things telemetry may ever count. Closed set: no free-form
/// events, no identifiers, no content.
enum TelemetryEvent {
  crash,
  engineFailure,
  vpnStartFailure,
  healthCheckFailure,
  aiUnavailable,
  storageFailure,
}

/// Privacy-first telemetry abstraction.
///
/// - **Off by default**; only an explicit opt-in turns it on.
/// - Records only [TelemetryEvent] counts per day, plus app/Android version
///   when a report is built. No install ID, device ID, account, IP, URL,
///   domain, query, app name or content.
/// - SafeGuard has no analytics server: the shipped implementation keeps
///   the counts **on the device** and shows them to the user. A future
///   transport would send exactly [TelemetryReport] and nothing else.
abstract interface class Telemetry {
  bool get enabled;
  Future<void> setEnabled(bool enabled);
  Future<void> count(TelemetryEvent event);
  Future<TelemetryReport> report();
  Future<void> clear();
}

class TelemetryReport {
  const TelemetryReport(this.days);

  /// yyyy-mm-dd → event → count (at most 30 days).
  final Map<String, Map<TelemetryEvent, int>> days;

  int total(TelemetryEvent e) =>
      days.values.fold(0, (sum, d) => sum + (d[e] ?? 0));

  bool get isEmpty => days.isEmpty;
}

class LocalTelemetry implements Telemetry {
  LocalTelemetry(this._store, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final KeyValueStore _store;
  final DateTime Function() _clock;
  static const _keyEnabled = 'telemetry.enabled';
  static const _keyCounts = 'telemetry.counts';
  static const _maxDays = 30;

  bool _enabled = false;
  @override
  bool get enabled => _enabled;

  Future<void> load() async {
    _enabled = await _store.read(_keyEnabled) == 'true';
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _store.write(_keyEnabled, '$enabled');
    // Opting out deletes what was counted.
    if (!enabled) await clear();
  }

  /// Serialises read-modify-write so concurrent counts aren't lost.
  Future<void> _queue = Future.value();

  @override
  Future<void> count(TelemetryEvent event) {
    if (!_enabled) return Future.value();
    return _queue = _queue.then((_) => _count(event));
  }

  Future<void> _count(TelemetryEvent event) async {
    try {
      final days = await _read();
      final d = _clock();
      final day =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final bucket = days.putIfAbsent(day, () => {});
      bucket[event] = (bucket[event] ?? 0) + 1;
      final keep = (days.keys.toList()..sort()).reversed.take(_maxDays).toSet();
      days.removeWhere((k, _) => !keep.contains(k));
      await _store.write(
        _keyCounts,
        jsonEncode({
          for (final e in days.entries)
            e.key: {for (final c in e.value.entries) c.key.name: c.value},
        }),
      );
    } catch (_) {
      // Counting must never break the app.
    }
  }

  @override
  Future<TelemetryReport> report() async => TelemetryReport(await _read());

  @override
  Future<void> clear() => _store.delete(_keyCounts);

  Future<Map<String, Map<TelemetryEvent, int>>> _read() async {
    final raw = await _store.read(_keyCounts);
    if (raw == null) return {};
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return {};
      return {
        for (final day in j.entries)
          if (day.key is String && day.value is Map)
            day.key as String: {
              for (final c in (day.value as Map).entries)
                if (TelemetryEvent.values.asNameMap()[c.key] != null &&
                    c.value is int)
                  TelemetryEvent.values.asNameMap()[c.key]!: c.value as int,
            },
      };
    } catch (_) {
      return {};
    }
  }
}
