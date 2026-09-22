enum ThemePreference { dark, light, system }

class AppSettings {
  const AppSettings({
    this.onboardingCompleted = false,
    this.theme = ThemePreference.dark,
    this.appLockEnabled = true,
  });

  final bool onboardingCompleted;
  final ThemePreference theme;

  /// Ask for the PIN when the app opens or returns from background.
  final bool appLockEnabled;

  AppSettings copyWith({
    bool? onboardingCompleted,
    ThemePreference? theme,
    bool? appLockEnabled,
  }) {
    return AppSettings(
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      theme: theme ?? this.theme,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
    );
  }

  Map<String, Object> toJson() => {
    'onboardingCompleted': onboardingCompleted,
    'theme': theme.name,
    'appLockEnabled': appLockEnabled,
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
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.onboardingCompleted == onboardingCompleted &&
      other.theme == theme &&
      other.appLockEnabled == appLockEnabled;

  @override
  int get hashCode => Object.hash(onboardingCompleted, theme, appLockEnabled);
}

abstract interface class SettingsRepository {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}
