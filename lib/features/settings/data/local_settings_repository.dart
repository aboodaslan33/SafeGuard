import 'dart:convert';

import '../../../core/storage/stores.dart';
import '../domain/app_settings.dart';

class LocalSettingsRepository implements SettingsRepository {
  const LocalSettingsRepository(this._store);

  final KeyValueStore _store;
  static const _key = 'settings.v1';

  @override
  Future<AppSettings> load() async {
    final raw = await _store.read(_key);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return const AppSettings();
    }
  }

  @override
  Future<void> save(AppSettings settings) =>
      _store.write(_key, jsonEncode(settings.toJson()));
}
