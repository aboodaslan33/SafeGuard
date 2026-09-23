import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import '../core/design_system/design_system.dart';
import '../core/i18n/i18n.dart';
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
        // Detect interruptions and let native try a safe recovery.
        widget.dependencies.protection.onResume();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _router.dispose();
    super.dispose();
  }

  AppLanguage? _language;

  @override
  Widget build(BuildContext context) {
    final settings = widget.dependencies.settings;
    return AppScope(
      dependencies: widget.dependencies,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final language = settings.settings.language;
          I18n.current = language;
          if (_language != language) {
            // Native screens (the "app protected" screen) follow along.
            widget.dependencies.protection.engine
                .setUiLanguage(language)
                .catchError((Object _) {});
          }
          if (_language != null && _language != language) {
            // Strings come from tr() in build methods: rebuild every page.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) I18n.rebuildAll(context);
            });
          }
          _language = language;
          return MaterialApp.router(
            title: 'SafeGuard',
            debugShowCheckedModeBanner: false,
            routerConfig: _router,
            locale: language.locale,
            supportedLocales: [for (final l in AppLanguage.values) l.locale],
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
          );
        },
      ),
    );
  }
}
