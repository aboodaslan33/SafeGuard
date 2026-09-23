import 'dart:ui';

import 'package:flutter/material.dart';

import '../design_system/design_system.dart';
import '../i18n/i18n.dart';
import 'app_logger.dart';

/// Installs global handlers for errors that escape feature code.
///
/// - Framework errors (build/layout/paint) → logged; in release the broken
///   widget is replaced by a calm placeholder instead of a red screen.
/// - Uncaught async errors → logged and marked handled so the app keeps
///   running; features are expected to use `guard()` for anything they own.
abstract final class ErrorBoundary {
  static void install() {
    FlutterError.onError = (details) {
      AppLogger.error('flutter', details.exception, details.stack);
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      AppLogger.error('uncaught', error, stack);
      return true;
    };

    ErrorWidget.builder = (details) => const _BrokenWidgetPlaceholder();
  }
}

class _BrokenWidgetPlaceholder extends StatelessWidget {
  const _BrokenWidgetPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SgColors>() ?? SgColors.dark;
    return Container(
      padding: const EdgeInsets.all(SgSpace.x4),
      alignment: Alignment.center,
      child: Text(
        tr('تعذّر عرض هذا الجزء', "This part couldn't be displayed"),
        textDirection: I18n.current.direction,
        style: TextStyle(
          color: colors.textTertiary,
          fontSize: 13,
          fontFamily: SgTypography.fontFamily,
        ),
      ),
    );
  }
}
