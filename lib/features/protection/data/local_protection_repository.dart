import 'dart:convert';

import '../../../core/error/app_logger.dart';
import '../../../core/storage/stores.dart';
import '../domain/protection.dart';

class LocalProtectionRepository implements ProtectionRepository {
  const LocalProtectionRepository(this._store);

  final KeyValueStore _store;
  static const _key = 'protection.v1';

  @override
  Future<ProtectionState> load() async {
    final raw = await _store.read(_key);
    if (raw == null) return ProtectionState.initial();
    try {
      return ProtectionState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e, s) {
      // Fail closed: unreadable policy means full protection, not none.
      AppLogger.error('protection', e, s);
      return ProtectionState.initial();
    }
  }

  @override
  Future<void> save(ProtectionState state) =>
      _store.write(_key, state.encode());
}
