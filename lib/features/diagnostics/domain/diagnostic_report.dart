/// Diagnostic report for "copy diagnostic information".
///
/// Privacy by construction: only the keys in [DiagnosticReport.fields] are
/// ever shown or copied, and every value is reduced to a boolean, a number
/// or a short token. Anything else — a domain, a query, a package name, a
/// keyword — can't pass even if the native side sent it by mistake.
class DiagnosticReport {
  DiagnosticReport(this.rows);

  /// (key, value) in display order.
  final List<(String, String)> rows;

  /// Whitelisted native keys, in display order, grouped for the screen.
  static const fields = <String, List<String>>{
    'device': ['androidRelease', 'sdkInt', 'manufacturer', 'model'],
    'vpn': [
      'protectionEnabled',
      'vpnPermission',
      'vpnState',
      'otherVpnActive',
      'safeMode',
      'paused',
      'mode',
    ],
    'dns': [
      'dnsFilterActive',
      'upstreamAvailable',
      'upstreamFailing',
      'privateDnsStrict',
      'rulesReady',
      'bundledLists',
      'userRules',
      'keywords',
    ],
    'features': [
      'searchEnabled',
      'aiEnabled',
      'aiTextModel',
      'aiImageModel',
      'protectedApps',
      'accessibility',
    ],
    'system': [
      'databaseOk',
      'logRetention',
      'logWriteFailures',
      'batteryOptimizationIgnored',
      'openIncidents',
      'lastBoot',
    ],
  };

  static final _token = RegExp(r'^[A-Za-z0-9 ._:\-()]{1,40}$');

  /// Reduces any value to something safe to show, or "—".
  static String sanitize(Object? v) {
    if (v == null) return '—';
    if (v is bool) return v ? 'yes' : 'no';
    if (v is num) return v.toString();
    if (v is Map) {
      // Category → count maps only (e.g. bundled list sizes).
      final parts = <String>[];
      for (final e in v.entries) {
        final k = e.key, n = e.value;
        if (k is String && n is num && _token.hasMatch(k)) parts.add('$k=$n');
      }
      return parts.isEmpty ? '—' : parts.join(', ');
    }
    if (v is String && _token.hasMatch(v)) return v;
    return '[redacted]';
  }

  factory DiagnosticReport.build({
    required Map<String, Object?> native,
    required String appVersion,
    required String flavor,
    required String buildMode,
    required String language,
  }) {
    final rows = <(String, String)>[
      ('appVersion', sanitize(appVersion)),
      ('flavor', sanitize(flavor)),
      ('buildMode', sanitize(buildMode)),
      ('language', sanitize(language)),
    ];
    for (final group in fields.values) {
      for (final key in group) {
        rows.add((key, sanitize(native[key])));
      }
    }
    return DiagnosticReport(rows);
  }

  String value(String key) =>
      rows.firstWhere((r) => r.$1 == key, orElse: () => (key, '—')).$2;

  /// Plain text for the clipboard (English keys, for support).
  String toText() {
    final b = StringBuffer('SafeGuard diagnostics\n');
    for (final (k, v) in rows) {
      b.writeln('$k: $v');
    }
    b.write(
      'Contains no browsing history, search text, domains, app names, '
      'keywords, PIN or personal data.',
    );
    return b.toString();
  }
}
