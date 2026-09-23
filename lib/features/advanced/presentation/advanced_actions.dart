import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
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
        !await requirePin(context, reason: 'لإلغاء قفل إعدادات الحماية')) {
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
      title: 'إيقاف مؤقت للحماية',
      subtitle:
          'تتوقف الفلترة للمدة المختارة ثم تعود تلقائيًا، حتى لو كان '
          'التطبيق مغلقًا. يُسجَّل الإيقاف في سجل الحماية.',
      builder: (context) => Column(
        children: [
          for (final m in const [5, 10, 30])
            SgChoiceRow(
              label: '$m دقائق',
              selected: false,
              onTap: () => Navigator.of(context).pop(m),
            ),
        ],
      ),
    );
    if (minutes == null || !context.mounted) return;
    if (!await requirePin(
      context,
      reason: 'لإيقاف الحماية مؤقتًا لمدة $minutes دقائق',
    )) {
      return;
    }
    final result = await protection.startPause(minutes);
    if (!context.mounted) return;
    showSgSnack(context, switch (result) {
      Ok() => 'الحماية متوقفة مؤقتًا لمدة $minutes دقائق.',
      Err(:final failure) => failure.message,
    });
  }

  /// Safe Mode: stop filtering so a network problem can't keep the device
  /// offline. Explains the trade-off, then the PIN.
  static Future<void> enterSafeMode(BuildContext context) async {
    final protection = AppScope.of(context).protection;
    final ok = await showSgConfirmDialog(
      context,
      title: 'تشغيل وضع الأمان؟',
      message:
          'يوقف وضع الأمان اتصال VPN الخاص بـ SafeGuard وكل الفلترة، '
          'لاستعادة الإنترنت إذا تسببت الحماية في انقطاعه. لن تعود الحماية '
          'تلقائيًا (ولا بعد إعادة التشغيل) حتى تعيد تفعيلها بنفسك.',
      confirmLabel: 'متابعة',
    );
    if (!ok || !context.mounted) return;
    if (!await requirePin(context, reason: 'لتشغيل وضع الأمان')) return;
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
      title: 'مسح سجل الحماية؟',
      message:
          'يُحذف سجل الحظر والإحصاءات وبلاغات الحظر الخاطئ من هذا الجهاز. '
          'لا تتغير إعدادات الحماية.',
      confirmLabel: 'مسح',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    if (!await requirePin(context, reason: 'لمسح سجل الحماية')) return;
    try {
      await deps.protection.engine.clearLogs();
      await deps.protection.refreshStats();
      await deps.protection.refreshAi();
      if (context.mounted) showSgSnack(context, 'مُسح سجل الحماية.');
    } on AppFailure catch (f) {
      if (context.mounted) showSgSnack(context, f.message);
    }
  }

  /// Secure defaults for every setting. Keeps the PIN, lists, keywords,
  /// protected apps and logs.
  static Future<void> resetProtection(BuildContext context) async {
    final protection = AppScope.of(context).protection;
    final confirmed = await showSgConfirmDialog(
      context,
      title: 'إعادة ضبط الحماية؟',
      message:
          'تعود كل إعدادات الحماية إلى الوضع الافتراضي الآمن: كل الفئات '
          'مفعّلة، البحث الآمن والحماية الذكية بإعداداتهما الافتراضية، وينتهي '
          'أي إيقاف مؤقت أو وضع أمان. تبقى رمز PIN والقوائم والكلمات '
          'والتطبيقات المحمية والسجل كما هي.',
      confirmLabel: 'إعادة الضبط',
    );
    if (!confirmed || !context.mounted) return;
    if (!await requirePin(context, reason: 'لإعادة ضبط الحماية')) return;
    final result = await protection.resetProtection();
    if (!context.mounted) return;
    showSgSnack(context, switch (result) {
      Ok() => 'أُعيد ضبط إعدادات الحماية.',
      Err(:final failure) => failure.message,
    });
  }

  /// Exports non-sensitive settings to a file the user chooses.
  static Future<void> exportSettings(BuildContext context) async {
    final confirmed = await showSgConfirmDialog(
      context,
      title: 'تصدير الإعدادات',
      message:
          'يُحفظ ملف JSON فيه: وضع الحماية والفئات وإعدادات البحث والحماية '
          'الذكية والأقفال، وقوائم النطاقات والكلمات المحظورة، وأسماء حزم '
          'التطبيقات المحمية.\n\nلا يتضمن: رمز PIN، السجل، الإحصاءات، '
          'البلاغات، أو أي مفاتيح. انتبه: قوائمك قد تكشف تفضيلاتك لمن يرى الملف.',
      confirmLabel: 'متابعة',
    );
    if (!confirmed || !context.mounted) return;
    if (!await requirePin(context, reason: 'لتصدير الإعدادات')) return;
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
        ExportResult.saved => 'حُفظت الإعدادات في الملف الذي اخترته.',
        ExportResult.cancelled => 'أُلغي التصدير.',
        ExportResult.failed => 'تعذّر حفظ الملف.',
      });
    } on AppFailure catch (f) {
      if (context.mounted) showSgSnack(context, f.message);
    }
  }
}
