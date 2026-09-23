import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../../../core/i18n/i18n.dart';

/// Each language is named in itself so it can be found whatever is shown.
String languageLabel(AppLanguage l) => switch (l) {
  AppLanguage.ar => 'العربية',
  AppLanguage.en => 'English',
};

/// Language picker, also used on the welcome screen.
Future<void> pickLanguage(BuildContext context) async {
  final settings = AppScope.of(context).settings;
  final current = settings.settings.language;
  final picked = await showSgBottomSheet<AppLanguage>(
    context,
    title: tr('اللغة', 'Language'),
    builder: (context) => Column(
      children: [
        for (final value in AppLanguage.values)
          SgChoiceRow(
            label: languageLabel(value),
            icon: Icons.translate_rounded,
            selected: value == current,
            onTap: () => Navigator.of(context).pop(value),
          ),
      ],
    ),
  );
  if (picked == null || picked == current) return;
  final result = await settings.setLanguage(picked);
  if (result case Err(:final failure) when context.mounted) {
    showSgSnack(context, failure.message);
  }
}
