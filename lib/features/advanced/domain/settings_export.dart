import 'dart:convert';

import '../../protection/domain/protection.dart';
import '../../settings/domain/app_settings.dart';

/// Builds the "Export settings" file.
///
/// Contains only settings the user chose: mode, categories, search and AI
/// settings, locks, custom lists, keywords and protected app package names.
/// Never contains the PIN (or its hash/salt), the per-install hashing key,
/// protection logs, statistics, false-positive reports or any content.
abstract final class SettingsExport {
  static const format = 'safeguard-settings';
  static const version = 1;

  static Map<String, Object?> build({
    required ProtectionState state,
    required SearchSettings search,
    required AiSettings ai,
    required AppSettings app,
    required List<DomainRule> blocked,
    required List<DomainRule> allowed,
    required List<CustomKeyword> keywords,
    required List<InstalledApp> protectedApps,
    required String appVersion,
    required DateTime now,
  }) => {
    'format': format,
    'version': version,
    'appVersion': appVersion,
    'exportedAt': now.toUtc().toIso8601String(),
    'protection': {
      'enabled': state.enabled,
      'mode': state.mode.name,
      'categories': {
        for (final c in ProtectionCategory.values) c.id: state.isChosen(c),
      },
    },
    'search': search.toMap(),
    'ai': ai.toMap(),
    'locks': {
      'appLock': app.appLockEnabled,
      'protectionLock': app.protectionLocked,
    },
    'blockedDomains': [
      for (final r in blocked)
        {'domain': r.domain, 'category': r.category?.id ?? 'custom'},
    ],
    'allowedDomains': [
      for (final r in allowed)
        {'domain': r.domain, 'includeSubdomains': r.includeSubdomains},
    ],
    'keywords': [
      for (final k in keywords)
        {'keyword': k.keyword, 'category': k.category?.id ?? 'custom'},
    ],
    'protectedApps': [for (final a in protectedApps) a.packageName],
    'notIncluded': [
      'pin',
      'logs',
      'statistics',
      'false_positive_reports',
      'device_keys',
    ],
  };

  static String encode(Map<String, Object?> data) =>
      const JsonEncoder.withIndent('  ').convert(data);
}
