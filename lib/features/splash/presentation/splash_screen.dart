import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';

/// Shown while local data loads. The router moves on by itself once
/// [AppDependencies.status] becomes ready; this screen only renders the
/// brand and, if loading failed, a way to retry.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final deps = AppScope.of(context);
      if (deps.status != BootStatus.ready) unawaited(deps.initialize());
    });
  }

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: deps,
        builder: (context, _) {
          if (deps.status == BootStatus.failed) {
            return ErrorState(
              title: 'تعذّر تحميل إعداداتك',
              message: deps.failure?.message,
              onRetry: deps.initialize,
            );
          }
          return Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: SgMotion.slow,
              curve: SgMotion.standard,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 6 * (1 - t)),
                  child: child,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ShieldMark(size: 56),
                  const SizedBox(height: SgSpace.x5),
                  Text(
                    'SafeGuard',
                    textDirection: TextDirection.ltr,
                    style: context.text.displaySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
