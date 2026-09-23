enum ThemePreference { dark, light, system }

class AppSettings {
  const AppSettings({
    this.onboardingCompleted = false,
    this.theme = ThemePreference.dark,
    this.appLockEnabled = true,
    this.protectionLocked = false,
  });

  final bool onboardingCompleted;
  final ThemePreference theme;

  /// Ask for the PIN when the app opens or returns from background.
  final bool appLockEnabled;

  /// Protection Lock: every change to protection settings needs the PIN
  /// (not only loosening ones).
  final bool protectionLocked;

  AppSettings copyWith({
    bool? onboardingCompleted,
    ThemePreference? theme,
    bool? appLockEnabled,
    bool? protectionLocked,
  }) {
    return AppSettings(
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      theme: theme ?? this.theme,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      protectionLocked: protectionLocked ?? this.protectionLocked,
    );
  }

  Map<String, Object> toJson() => {
    'onboardingCompleted': onboardingCompleted,
    'theme': theme.name,
    'appLockEnabled': appLockEnabled,
    'protectionLocked': protectionLocked,
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
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.onboardingCompleted == onboardingCompleted &&
      other.theme == theme &&
      other.appLockEnabled == appLockEnabled &&
      other.protectionLocked == protectionLocked;

  @override
  int get hashCode =>
      Object.hash(onboardingCompleted, theme, appLockEnabled, protectionLocked);
}

abstract interface class SettingsRepository {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}
