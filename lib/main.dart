import 'package:flutter/material.dart';

import 'app/app_dependencies.dart';
import 'app/safeguard_app.dart';
import 'core/error/error_boundary.dart';
import 'core/licenses.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorBoundary.install();
  registerThirdPartyLicenses();

  // Loading happens behind the splash screen, not before runApp, so the
  // first frame appears immediately after the native launch screen.
  final dependencies = AppDependencies.production();
  runApp(SafeGuardApp(dependencies: dependencies));
}
