import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-sensitive preferences (theme, protection toggles).
abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> clear();
}

/// Secrets (PIN hash, attempt counters). Backed by the Android Keystore.
abstract interface class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> clear();
}

class SharedPrefsStore implements KeyValueStore {
  SharedPrefsStore([SharedPreferencesAsync? prefs])
    : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  /// All keys are namespaced so [clear] never touches other plugins' data.
  static const _prefix = 'sg.';

  @override
  Future<String?> read(String key) => _prefs.getString('$_prefix$key');

  @override
  Future<void> write(String key, String value) =>
      _prefs.setString('$_prefix$key', value);

  @override
  Future<void> delete(String key) => _prefs.remove('$_prefix$key');

  @override
  Future<void> clear() async {
    final ours = (await _prefs.getKeys())
        .where((k) => k.startsWith(_prefix))
        .toSet();
    if (ours.isEmpty) return;
    await _prefs.clear(allowList: ours);
  }
}

class KeystoreSecureStore implements SecureStore {
  KeystoreSecureStore()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(storageNamespace: 'safeguard_secure'),
      );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> clear() => _storage.deleteAll();
}

/// In-memory implementation for tests and previews.
class MemoryStore implements KeyValueStore, SecureStore {
  final Map<String, String> values = {};

  /// When set, every operation throws — used to test failure paths.
  Object? failWith;

  void _check() {
    if (failWith != null) throw failWith!;
  }

  @override
  Future<String?> read(String key) async {
    _check();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _check();
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _check();
    values.remove(key);
  }

  @override
  Future<void> clear() async {
    _check();
    values.clear();
  }
}
