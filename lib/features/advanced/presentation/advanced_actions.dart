import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';
import '../../settings/presentation/settings_screen.dart';
import '../domain/settings_export.dart';

/// Phase 5 user actions. Every one that weakens protection or exposes
/// settings asks for the PIN; none can be completed without it.
abstract final class AdvancedActions {
  /// Turning the lock on is free; turning it off needs the PIN.
  static Future<void> setProtectionLock(
    BuildContext context,
    bool locked,
  ) async {
    final settings = AppScope.of(context).settings;
    if (!locked &&
        !await requirePin(
          context,
          reason: tr(
            'لإلغاء قفل إعدادات الحماية',
            'to unlock protection settings',
          ),
        )) {
      return;
    }
    final result = await settings.setProtectionLock(locked);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  /// Temporary unlock: choose 5/10/30 minutes, then the PIN. Filtering
  /// resumes automatically; the start is logged locally.
  static Future<void> startTemporaryUnlock(BuildContext context) async {
    final protection = AppScope.of(context).protection;
    final minutes = await showSgBottomSheet<int>(
      context,
      title: tr('إيقاف مؤقت للحماية', 'Pause protection'),
      subtitle: tr(
        'تتوقف الفلترة للمدة المختارة ثم تعود تلقائيًا، حتى لو كان '
            'التطبيق مغلقًا. يُسجَّل الإيقاف في سجل الحماية.',
        'Filtering stops for the chosen time and resumes automatically, even if the app is closed. The pause is recorded in the protection log.',
      ),
      builder: (context) => Column(
        children: [
          for (final m in const [5, 10, 30])
            SgChoiceRow(
              label: tr('$m دقائق', '$m minutes'),
              selected: false,
              onTap: () => Navigator.of(context).pop(m),
            ),
        ],
      ),
    );
    if (minutes == null || !context.mounted) return;
    if (!await requirePin(
      context,
      reason: tr(
        'لإيقاف الحماية مؤقتًا لمدة $minutes دقائق',
        'to pause protection for $minutes minutes',
      ),
    )) {
      return;
    }
    final result = await protection.startPause(minutes);
    if (!context.mounted) return;
    showSgSnack(context, switch (result) {
      Ok() => tr(
        'الحماية متوقفة مؤقتًا لمدة $minutes دقائق.',
        'Protection paused for $minutes minutes.',
      ),
      Err(:final failure) => failure.message,
    });
  }

  /// Safe Mode: stop filtering so a network problem can't keep the device
  /// offline. Explains the trade-off, then the PIN.
  static Future<void> enterSafeMode(BuildContext context) async {
    final protection = AppScope.of(context).protection;
    final ok = await showSgConfirmDialog(
      context,
      title: tr('تشغيل وضع الأمان؟', 'Turn on Safe Mode?'),
      message: tr(
        'يوقف وضع الأمان اتصال VPN الخاص بـ SafeGuard وكل الفلترة، '
            'لاستعادة الإنترنت إذا تسببت الحماية في انقطاعه. لن تعود الحماية '
            'تلقائيًا (ولا بعد إعادة التشغيل) حتى تعيد تفعيلها بنفسك.',
        "Safe Mode stops SafeGuard's VPN connection and all filtering, to restore internet access if protection broke it. Protection won't come back on its own (not even after a restart) until you turn it on yourself.",
      ),
      confirmLabel: tr('متابعة', 'Continue'),
    );
    if (!ok || !context.mounted) return;
    if (!await requirePin(
      context,
      reason: tr('لتشغيل وضع الأمان', 'to turn on Safe Mode'),
    )) {
      return;
    }
    final result = await protection.enterSafeMode();
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  static Future<void> exitSafeMode(BuildContext context) async {
    if (!await ProtectionActions.ensureVpnConsent(context) ||
        !context.mounted) {
      return;
    }
    final result = await AppScope.of(context).protection.exitSafeMode();
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  static Future<void> clearLogs(BuildContext context) async {
    final deps = AppScope.of(context);
    final confirmed = await showSgConfirmDialog(
      context,
      title: tr('مسح سجل الحماية؟', 'Clear protection log?'),
      message: tr(
        'يُحذف سجل الحظر والإحصاءات وبلاغات الحظر الخاطئ من هذا الجهاز. '
            'لا تتغير إعدادات الحماية.',
        "The block log, statistics and false-positive reports are deleted from this device. Protection settings don't change.",
      ),
      confirmLabel: tr('مسح', 'Clear'),
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    if (!await requirePin(
      context,
      reason: tr('لمسح سجل الحماية', 'to clear the protection log'),
    )) {
      return;
    }
    try {
      await deps.protection.engine.clearLogs();
      await deps.protection.refreshStats();
      await deps.protection.refreshAi();
      if (context.mounted) {
        showSgSnack(
          context,
          tr('مُسح سجل الحماية.', 'Protection log cleared.'),
        );
      }
    } on AppFailure catch (f) {
      if (context.mounted) showSgSnack(context, f.message);
    }
  }

  /// Log retention. Any change needs the PIN (the log is what a parent
  /// reviews); a shorter period deletes older entries, after confirmation.
  /// Returns the value now in force, or null when unchanged.
  static Future<LogRetention?> chooseLogRetention(
    BuildContext context,
    LogRetention current,
  ) async {
    final engine = AppScope.of(context).protection.engine;
    final picked = await showSgBottomSheet<LogRetention>(
      context,
      title: tr('مدة الاحتفاظ بالسجل', 'Log retention'),
      subtitle: tr(
        'يُحذف ما هو أقدم تلقائيًا. السجل لا يحوي نصوص بحث أو محتوى.',
        'Older entries are deleted automatically. The log contains no search text or content.',
      ),
      builder: (context) => Column(
        children: [
          for (final value in LogRetention.values)
            SgChoiceRow(
              label: value.label,
              icon: value == LogRetention.never
                  ? Icons.block_outlined
                  : Icons.history_rounded,
              selected: value == current,
              onTap: () => Navigator.of(context).pop(value),
            ),
        ],
      ),
    );
    if (picked == null || picked == current || !context.mounted) return null;
    if (picked.isShorterThan(current)) {
      final confirmed = await showSgConfirmDialog(
        context,
        title: tr('تقصير مدة السجل؟', 'Shorten log retention?'),
        message: picked == LogRetention.never
            ? tr(
                'يُحذف سجل الحماية الحالي ولن يُسجَّل شيء بعد الآن. '
                    'تبقى الحماية تعمل كما هي.',
                'The current protection log is deleted and nothing will be recorded from now on. Protection keeps working as before.',
              )
            : tr(
                'تُحذف الأحداث الأقدم من ${picked.label} من هذا الجهاز.',
                'Events older than ${picked.label} are deleted from this device.',
              ),
        confirmLabel: tr('متابعة', 'Continue'),
        destructive: true,
      );
      if (!confirmed || !context.mounted) return null;
    }
    if (!await requirePin(
      context,
      reason: tr('لتغيير مدة الاحتفاظ بالسجل', 'to change log retention'),
    )) {
      return null;
    }
    try {
      final applied = await engine.setLogRetention(picked);
      if (context.mounted) {
        await AppScope.of(context).protection.refreshStats();
      }
      return applied;
    } on AppFailure catch (f) {
      if (context.mounted) showSgSnack(context, f.message);
      return null;
    }
  }

  /// Secure defaults for every setting. Keeps the PIN, lists, keywords,
  /// protected apps and logs.
  static Future<void> resetProtection(BuildContext context) async {
    final protection = AppScope.of(context).protection;
    final confirmed = await showSgConfirmDialog(
      context,
      title: tr('إعادة ضبط الحماية؟', 'Reset protection?'),
      message: tr(
        'تعود كل إعدادات الحماية إلى الوضع الافتراضي الآمن: كل الفئات '
            'مفعّلة، البحث الآمن والحماية الذكية بإعداداتهما الافتراضية، وينتهي '
            'أي إيقاف مؤقت أو وضع أمان. تبقى رمز PIN والقوائم والكلمات '
            'والتطبيقات المحمية والسجل كما هي.',
        'All protection settings return to the secure defaults: every category on, SafeSearch and AI protection at their defaults, and any pause or Safe Mode ends. Your PIN, lists, keywords, protected apps and log stay as they are.',
      ),
      confirmLabel: tr('إعادة الضبط', 'Reset'),
    );
    if (!confirmed || !context.mounted) return;
    if (!await requirePin(
      context,
      reason: tr('لإعادة ضبط الحماية', 'to reset protection'),
    )) {
      return;
    }
    final result = await protection.resetProtection();
    if (!context.mounted) return;
    showSgSnack(context, switch (result) {
      Ok() => tr(
        'أُعيد ضبط إعدادات الحماية.',
        'Protection settings were reset.',
      ),
      Err(:final failure) => failure.message,
    });
  }

  /// Exports non-sensitive settings to a file the user chooses.
  static Future<void> exportSettings(BuildContext context) async {
    final confirmed = await showSgConfirmDialog(
      context,
      title: tr('تصدير الإعدادات', 'Export settings'),
      message: tr(
        'يُحفظ ملف JSON فيه: وضع الحماية والفئات وإعدادات البحث والحماية '
            'الذكية والأقفال، وقوائم النطاقات والكلمات المحظورة، وأسماء حزم '
            'التطبيقات المحمية.\n\nلا يتضمن: رمز PIN، السجل، الإحصاءات، '
            'البلاغات، أو أي مفاتيح. انتبه: قوائمك قد تكشف تفضيلاتك لمن يرى الملف.',
        'A JSON file is saved with: protection mode, categories, search and AI settings, locks, domain and keyword lists, and package names of protected apps.\n\nNot included: PIN, log, statistics, reports or any keys. Note: your lists may reveal your preferences to anyone who sees the file.',
      ),
      confirmLabel: tr('متابعة', 'Continue'),
    );
    if (!confirmed || !context.mounted) return;
    if (!await requirePin(
      context,
      reason: tr('لتصدير الإعدادات', 'to export settings'),
    )) {
      return;
    }
    if (!context.mounted) return;
    final deps = AppScope.of(context);
    final p = deps.protection;
    try {
      final engine = p.engine;
      final json = SettingsExport.encode(
        SettingsExport.build(
          state: p.state,
          search: p.searchSettings,
          ai: p.aiSettings,
          app: deps.settings.settings,
          blocked: await engine.userRules(RuleAction.block),
          allowed: await engine.userRules(RuleAction.allow),
          keywords: await engine.keywords(),
          protectedApps: await engine.protectedApps(),
          appVersion: SettingsScreen.appVersion,
          now: DateTime.now(),
        ),
      );
      final result = await engine.saveExport(json);
      if (!context.mounted) return;
      showSgSnack(context, switch (result) {
        ExportResult.saved => tr(
          'حُفظت الإعدادات في الملف الذي اخترته.',
          'Settings were saved to the file you chose.',
        ),
        ExportResult.cancelled => tr('أُلغي التصدير.', 'Export cancelled.'),
        ExportResult.failed => tr(
          'تعذّر حفظ الملف.',
          "Couldn't save the file.",
        ),
      });
    } on AppFailure catch (f) {
      if (context.mounted) showSgSnack(context, f.message);
    }
  }
}
