/// Route paths. Keep all paths here so redirects and links can't drift.
abstract final class Routes {
  static const splash = '/';
  static const welcome = '/welcome';
  static const createPin = '/pin/create';
  static const lock = '/lock';

  static const home = '/home';
  static const status = '/status';
  static const settings = '/settings';

  static const verify = '/verify';
  static const changePin = '/change-pin';
  static const blocked = '/blocked';
  static const blocklist = '/rules/blocked';
  static const allowlist = '/rules/allowed';
  static const activity = '/activity';
  static const searchProtection = '/search-protection';
  static const appProtection = '/app-protection';

  static const _firstRun = {welcome, createPin};
  static const _entry = {splash, welcome, createPin, lock};

  static String lockFrom(String from) =>
      Uri(path: lock, queryParameters: {'from': from}).toString();
}

/// Everything the router needs to decide where the user may be.
class GateState {
  const GateState({
    required this.ready,
    required this.onboardingCompleted,
    required this.pinSet,
    required this.locked,
  });

  final bool ready;
  final bool onboardingCompleted;
  final bool pinSet;
  final bool locked;

  @override
  bool operator ==(Object other) =>
      other is GateState &&
      other.ready == ready &&
      other.onboardingCompleted == onboardingCompleted &&
      other.pinSet == pinSet &&
      other.locked == locked;

  @override
  int get hashCode => Object.hash(ready, onboardingCompleted, pinSet, locked);
}

/// Pure redirect policy (unit tested). Returns null to stay put.
///
/// Order matters: not loaded → splash; no PIN or onboarding → first-run
/// flow; locked → lock screen (remembering where the user was); otherwise
/// entry screens forward to the app.
String? resolveRedirect(Uri uri, GateState gate) {
  final path = uri.path;

  if (!gate.ready) return path == Routes.splash ? null : Routes.splash;

  if (!gate.onboardingCompleted || !gate.pinSet) {
    return Routes._firstRun.contains(path) ? null : Routes.welcome;
  }

  if (gate.locked) {
    if (path == Routes.lock) return null;
    // Entry screens and the PIN gate (whose caller awaits a result) can't
    // be resumed meaningfully; fall back to Home for those.
    final resumable = !Routes._entry.contains(path) && path != Routes.verify;
    final from = resumable ? uri.toString() : Routes.home;
    return Routes.lockFrom(from);
  }

  if (Routes._entry.contains(path)) {
    final from = path == Routes.lock ? uri.queryParameters['from'] : null;
    return _isInternal(from) ? from! : Routes.home;
  }
  return null;
}

/// Only same-app paths are valid return targets ("/x", not "//host").
bool _isInternal(String? path) =>
    path != null && path.startsWith('/') && !path.startsWith('//');
