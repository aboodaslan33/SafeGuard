import '../../../core/i18n/i18n.dart';

enum ThemePreference { dark, light, system }

class AppSettings {
  const AppSettings({
    this.onboardingCompleted = false,
    this.theme = ThemePreference.dark,
    this.appLockEnabled = true,
    this.protectionLocked = false,
    this.language = AppLanguage.ar,
  });

  final bool onboardingCompleted;
  final ThemePreference theme;

  /// Ask for the PIN when the app opens or returns from background.
  final bool appLockEnabled;

  /// Protection Lock: every change to protection settings needs the PIN
  /// (not only loosening ones).
  final bool protectionLocked;

  /// UI language: Arabic (RTL, default) or English (LTR).
  final AppLanguage language;

  AppSettings copyWith({
    bool? onboardingCompleted,
    ThemePreference? theme,
    bool? appLockEnabled,
    bool? protectionLocked,
    AppLanguage? language,
  }) {
    return AppSettings(
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      theme: theme ?? this.theme,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      protectionLocked: protectionLocked ?? this.protectionLocked,
      language: language ?? this.language,
    );
  }

  Map<String, Object> toJson() => {
    'onboardingCompleted': onboardingCompleted,
    'theme': theme.name,
    'appLockEnabled': appLockEnabled,
    'protectionLocked': protectionLocked,
    'language': language.name,
  };

  /// Tolerant decoding: unknown or missing fields fall back to defaults so
  /// older/newer app versions can read each other's data.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const d = AppSettings();
    return AppSettings(
      onboardingCompleted:
          json['onboardingCompleted'] as bool? ?? d.onboardingCompleted,
      theme: ThemePreference.values.asNameMap()[json['theme']] ?? d.theme,
      appLockEnabled: json['appLockEnabled'] as bool? ?? d.appLockEnabled,
      protectionLocked: json['protectionLocked'] as bool? ?? d.protectionLocked,
      language: AppLanguage.fromName(json['language']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.onboardingCompleted == onboardingCompleted &&
      other.theme == theme &&
      other.appLockEnabled == appLockEnabled &&
      other.protectionLocked == protectionLocked &&
      other.language == language;

  @override
  int get hashCode => Object.hash(
    onboardingCompleted,
    theme,
    appLockEnabled,
    protectionLocked,
    language,
  );
}

abstract interface class SettingsRepository {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}
