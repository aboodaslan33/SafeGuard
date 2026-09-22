import 'package:flutter_test/flutter_test.dart';
import 'package:safeguard/app/router/routes.dart';

GateState gate({
  bool ready = true,
  bool onboarded = true,
  bool pinSet = true,
  bool locked = false,
}) => GateState(
  ready: ready,
  onboardingCompleted: onboarded,
  pinSet: pinSet,
  locked: locked,
);

String? go(String location, GateState g) =>
    resolveRedirect(Uri.parse(location), g);

void main() {
  test('everything waits on the splash until data is loaded', () {
    expect(go(Routes.home, gate(ready: false)), Routes.splash);
    expect(go(Routes.splash, gate(ready: false)), isNull);
  });

  test('first run is confined to onboarding and PIN creation', () {
    final g = gate(onboarded: false, pinSet: false);
    expect(go(Routes.splash, g), Routes.welcome);
    expect(go(Routes.home, g), Routes.welcome);
    expect(go(Routes.welcome, g), isNull);
    expect(go(Routes.createPin, g), isNull);
  });

  test('a missing PIN sends the user back through setup', () {
    expect(go(Routes.home, gate(pinSet: false)), Routes.welcome);
  });

  test('locked app goes to the lock screen and remembers the target', () {
    final g = gate(locked: true);
    expect(go(Routes.settings, g), Routes.lockFrom(Routes.settings));
    expect(go(Routes.splash, g), Routes.lockFrom(Routes.home));
    expect(go(Routes.verify, g), Routes.lockFrom(Routes.home));
    expect(go(Routes.lock, g), isNull);
  });

  test('after unlock the user returns where they were', () {
    expect(go(Routes.lockFrom(Routes.settings), gate()), Routes.settings);
    expect(go(Routes.lock, gate()), Routes.home);
  });

  test('entry screens forward into the app; app screens stay', () {
    expect(go(Routes.splash, gate()), Routes.home);
    expect(go(Routes.welcome, gate()), Routes.home);
    expect(go(Routes.createPin, gate()), Routes.home);
    expect(go(Routes.status, gate()), isNull);
    expect(go(Routes.changePin, gate()), isNull);
  });

  test('lock "from" parameter cannot redirect off-app', () {
    final uri = Uri(path: Routes.lock, queryParameters: {'from': 'https://x'});
    expect(resolveRedirect(uri, gate()), Routes.home);
    final protocolRelative = Uri(
      path: Routes.lock,
      queryParameters: {'from': '//evil.test'},
    );
    expect(resolveRedirect(protocolRelative, gate()), Routes.home);
  });
}
