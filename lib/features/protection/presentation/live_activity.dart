import 'package:flutter/widgets.dart';

import '../../../app/app_dependencies.dart';
import 'protection_controller.dart';

/// Reloads a screen's data when new protection events are recorded
/// (DNS, search, apps, AI shield), so counters and logs update live
/// instead of only when the screen opens.
///
/// The native side bumps `activityVersion` at most twice a second; the
/// screen implements [onActivity] (usually its own `_load`).
mixin LiveActivityRefresh<T extends StatefulWidget> on State<T> {
  ProtectionController? _controller;
  int _seen = -1;

  /// Called when new events were recorded (or the log was cleared).
  Future<void> onActivity();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = AppScope.of(context).protection;
    if (!identical(c, _controller)) {
      _controller?.removeListener(_check);
      _controller = c..addListener(_check);
      _seen = c.activityVersion;
    }
  }

  void _check() {
    final v = _controller?.activityVersion ?? _seen;
    if (v == _seen || !mounted) return;
    _seen = v;
    onActivity();
  }

  @override
  void dispose() {
    _controller?.removeListener(_check);
    super.dispose();
  }
}
