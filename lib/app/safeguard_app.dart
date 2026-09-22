import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import '../core/design_system/design_system.dart';
import '../features/settings/domain/app_settings.dart';
import 'app_dependencies.dart';
import 'router/app_router.dart';

class SafeGuardApp extends StatefulWidget {
  const SafeGuardApp({super.key, required this.dependencies, this.router});

  final AppDependencies dependencies;

  /// Injected only by tests and design previews; the app builds its own.
  @visibleForTesting
  final GoRouter? router;

  @override
  State<SafeGuardApp> createState() => _SafeGuardAppState();
}

class _SafeGuardAppState extends State<SafeGuardApp> {
  /// Re-lock after the app has been in the background this long.
  static const _relockAfter = Duration(seconds: 30);

  late final GoRouter _router =
      widget.router ?? createRouter(widget.dependencies);
  late final AppLifecycleListener _lifecycle;
  DateTime? _hiddenAt;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => _hiddenAt = DateTime.now(),
      onShow: () {
        final hiddenAt = _hiddenAt;
        _hiddenAt = null;
        if (hiddenAt != null &&
            DateTime.now().difference(hiddenAt) >= _relockAfter) {
          widget.dependencies.security.lock();
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.dependencies.settings;
    return AppScope(
      dependencies: widget.dependencies,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp.router(
          title: 'SafeGuard',
          debugShowCheckedModeBanner: false,
          routerConfig: _router,
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: switch (settings.settings.theme) {
            ThemePreference.dark => ThemeMode.dark,
            ThemePreference.light => ThemeMode.light,
            ThemePreference.system => ThemeMode.system,
          },
          // Honour the user's font size up to a point where layouts still
          // hold; beyond 1.3× rows and the keypad start to wrap badly.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3),
              ),
              child: child!,
            );
          },
        ),
      ),
    );
  }
}
