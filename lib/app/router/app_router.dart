import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/design_system.dart';
import '../../core/i18n/i18n.dart';
import '../../features/activity/presentation/activity_screen.dart';
import '../../features/advanced/presentation/keywords_screen.dart';
import '../../features/advanced/presentation/statistics_screen.dart';
import '../../features/ai/presentation/ai_protection_screen.dart';
import '../../features/apps/presentation/app_protection_screen.dart';
import '../../features/blocking/presentation/blocked_content_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/pin/presentation/pin_screens.dart';
import '../../features/protection/domain/protection.dart';
import '../../features/rules/presentation/domain_rules_screen.dart';
import '../../features/search/presentation/search_protection_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/splash/presentation/splash_screen.dart';
import '../../features/status/presentation/status_screen.dart';
import '../app_dependencies.dart';
import 'app_shell.dart';
import 'routes.dart';

GoRouter createRouter(AppDependencies deps) {
  final gate = _GateNotifier(deps);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: gate,
    redirect: (context, state) => resolveRedirect(state.uri, gate.value),
    routes: [
      GoRoute(
        path: Routes.splash,
        pageBuilder: (c, s) => _fade(s, const SplashScreen()),
      ),
      GoRoute(
        path: Routes.welcome,
        pageBuilder: (c, s) => _fade(s, const OnboardingScreen()),
      ),
      GoRoute(
        path: Routes.createPin,
        builder: (c, s) => const PinSetupScreen(),
      ),
      GoRoute(
        path: Routes.lock,
        pageBuilder: (c, s) => _fade(s, const PinLockScreen()),
      ),
      GoRoute(
        path: Routes.verify,
        pageBuilder: (c, s) => MaterialPage(
          key: s.pageKey,
          fullscreenDialog: true,
          child: PinGateScreen(reason: s.extra as String?),
        ),
      ),
      GoRoute(
        path: Routes.blocklist,
        builder: (c, s) => const DomainRulesScreen(action: RuleAction.block),
      ),
      // PIN-gated by the caller (Settings) — every entry loosens protection.
      GoRoute(
        path: Routes.allowlist,
        builder: (c, s) => const DomainRulesScreen(action: RuleAction.allow),
      ),
      GoRoute(path: Routes.activity, builder: (c, s) => const ActivityScreen()),
      GoRoute(
        path: Routes.searchProtection,
        builder: (c, s) => const SearchProtectionScreen(),
      ),
      GoRoute(
        path: Routes.aiProtection,
        builder: (c, s) => const AiProtectionScreen(),
      ),
      GoRoute(path: Routes.keywords, builder: (c, s) => const KeywordsScreen()),
      GoRoute(
        path: Routes.statistics,
        builder: (c, s) => const StatisticsScreen(),
      ),
      GoRoute(
        path: Routes.appProtection,
        builder: (c, s) => const AppProtectionScreen(),
      ),
      GoRoute(
        path: Routes.changePin,
        builder: (c, s) => const PinSetupScreen(changing: true),
      ),
      GoRoute(
        path: Routes.blocked,
        pageBuilder: (c, s) => _fade(
          s,
          BlockedContentScreen(
            category: ProtectionCategory.fromId(
              s.uri.queryParameters['category'] ?? '',
            ),
            source: switch (s.uri.queryParameters['source']) {
              'ai' => EventSourceKind.ai,
              'search' => EventSourceKind.search,
              _ => null,
            },
            confidence:
                double.tryParse(s.uri.queryParameters['confidence'] ?? '') ?? 0,
          ),
        ),
      ),
      StatefulShellRoute.indexedStack(
        pageBuilder: (c, s, shell) => _fade(s, AppShell(shell: shell)),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: Routes.home, builder: (c, s) => const HomeScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.status,
                builder: (c, s) => const StatusScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.settings,
                builder: (c, s) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: ErrorState(
        title: tr('الصفحة غير موجودة', 'Page not found'),
        retryLabel: tr('العودة للرئيسية', 'Back to home'),
        onRetry: () => context.go(Routes.home),
      ),
    ),
  );
}

/// Derives [GateState] from the controllers and notifies the router only
/// when it actually changes. Refreshing on every controller notification
/// (e.g. a wrong PIN attempt) would needlessly re-run redirects under an
/// open PIN gate.
class _GateNotifier extends ValueNotifier<GateState> {
  _GateNotifier(this._deps) : super(_compute(_deps)) {
    _source.addListener(_update);
  }

  final AppDependencies _deps;
  late final Listenable _source = Listenable.merge([
    _deps,
    _deps.settings,
    _deps.security,
  ]);

  static GateState _compute(AppDependencies d) => GateState(
    ready: d.status == BootStatus.ready,
    onboardingCompleted: d.settings.settings.onboardingCompleted,
    pinSet: d.security.pinSet,
    locked:
        d.settings.settings.appLockEnabled &&
        d.security.pinSet &&
        !d.security.unlocked,
  );

  void _update() => value = _compute(_deps);

  @override
  void dispose() {
    _source.removeListener(_update);
    super.dispose();
  }
}

CustomTransitionPage<void> _fade(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: SgMotion.medium,
    reverseTransitionDuration: SgMotion.fast,
    transitionsBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: SgMotion.standard),
      child: child,
    ),
  );
}

/// Asks for the PIN before a sensitive action. Returns true when verified.
Future<bool> requirePin(BuildContext context, {required String reason}) async {
  final ok = await context.push<bool>(Routes.verify, extra: reason);
  return ok ?? false;
}
