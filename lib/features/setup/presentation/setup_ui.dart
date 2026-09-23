import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_controller.dart';
import '../../protection/presentation/protection_ui.dart';
import '../domain/setup_checks.dart';

/// Reads every fact the setup checks need. Each probe is guarded: a failing
/// one leaves its fact unknown instead of failing the whole screen.
Future<SetupFacts> loadSetupFacts(ProtectionController p) async {
  final engine = p.engine;
  if (!engine.isSupported) {
    return SetupFacts(
      supported: false,
      vpnPermission: false,
      snapshot: p.snapshot,
      protectionEnabled: p.state.enabled,
      accessibility: AccessibilityStatus.unsupported,
      protectedAppCount: 0,
    );
  }
  await p.refreshStatus();
  await p.refreshAppProtection();
  await p.refreshHealth();
  var permission = false;
  try {
    permission = await engine.hasVpnPermission();
  } catch (_) {}
  AlertsState? alerts;
  try {
    alerts = await engine.alertsState();
  } catch (_) {}
  bool? battery;
  try {
    final d = await engine.diagnostics();
    final b = d['batteryOptimizationIgnored'];
    battery = b is bool ? b : null;
  } catch (_) {}
  return SetupFacts(
    supported: true,
    vpnPermission: permission,
    snapshot: p.snapshot,
    protectionEnabled: p.state.enabled,
    accessibility: p.accessibility,
    protectedAppCount: p.protectedAppCount,
    batteryOptimizationIgnored: battery,
    alerts: alerts,
  );
}

/// Performs a check's action. Errors are shown, never swallowed.
Future<void> runCheckAction(BuildContext context, CheckAction action) async {
  final protection = AppScope.of(context).protection;
  final engine = protection.engine;
  try {
    switch (action) {
      case CheckAction.grantVpn:
        await ProtectionActions.ensureVpnConsent(context);
      case CheckAction.startProtection:
        if (protection.state.enabled) {
          await ProtectionActions.restart(context);
        } else {
          await ProtectionActions.setEnabled(context, true);
        }
      case CheckAction.openVpnSettings:
        await engine.openVpnSettings();
      case CheckAction.openPrivateDnsSettings:
        await engine.openPrivateDnsSettings();
      case CheckAction.openAppProtection:
        await context.push(Routes.appProtection);
      case CheckAction.openBatterySettings:
        await engine.openBatterySettings();
      case CheckAction.requestNotifications:
        final granted = await engine.requestNotificationPermission();
        if (!granted && context.mounted) {
          showSgSnack(
            context,
            tr(
              'لم يُسمح بالإشعارات. يمكنك السماح بها لاحقًا من إعدادات Android.',
              'Notifications weren\'t allowed. You can allow them later in Android settings.',
            ),
          );
        }
    }
  } catch (_) {
    if (context.mounted) {
      showSgSnack(
        context,
        tr(
          'تعذّر فتح الإعداد. افتحه يدويًا من إعدادات Android.',
          "Couldn't open that setting. Open it manually in Android settings.",
        ),
      );
    }
  }
}

extension SetupCheckText on SetupCheckId {
  String get title => switch (this) {
    SetupCheckId.vpnConsent => tr('موافقة VPN', 'VPN consent'),
    SetupCheckId.protectionRunning => tr('تشغيل الحماية', 'Protection running'),
    SetupCheckId.otherVpn => tr('تطبيق VPN آخر', 'Another VPN app'),
    SetupCheckId.privateDns => tr(
      '«DNS الخاص» في Android',
      'Android Private DNS',
    ),
    SetupCheckId.accessibility => tr(
      'خدمة حماية التطبيقات (تسهيل الاستخدام)',
      'App protection service (Accessibility)',
    ),
    SetupCheckId.notifications => tr('الإشعارات', 'Notifications'),
    SetupCheckId.battery => tr('تحسين البطارية', 'Battery optimisation'),
    SetupCheckId.alwaysOn => tr('VPN دائم التشغيل', 'Always-on VPN'),
  };

  String get why => switch (this) {
    SetupCheckId.vpnConsent => tr(
      'يُنشئ SafeGuard اتصال VPN محليًا على جهازك ليفحص أسماء النطاقات. Android يطلب موافقتك مرة واحدة.',
      'SafeGuard creates a local VPN on your device to check domain names. Android asks for your consent once.',
    ),
    SetupCheckId.protectionRunning => tr(
      'الفلترة تعمل فقط ما دام اتصال VPN المحلي قائمًا.',
      'Filtering only works while the local VPN connection is up.',
    ),
    SetupCheckId.otherVpn => tr(
      'Android يشغّل تطبيق VPN واحدًا فقط. عندما يعمل VPN آخر يتوقف SafeGuard، ولا يحاول SafeGuard إيقافه.',
      'Android runs only one VPN app at a time. While another VPN runs, SafeGuard stops — and it never tries to stop the other one.',
    ),
    SetupCheckId.privateDns => tr(
      'عندما يُضبط «DNS الخاص» على مزوّد محدد، يرسل Android أسماء النطاقات مشفّرة إليه مباشرة فتتجاوز الفلترة.',
      'When Private DNS is set to a specific provider, Android sends domain lookups encrypted straight to it, bypassing filtering.',
    ),
    SetupCheckId.accessibility => tr(
      'تعرف منها حماية التطبيقات اسم التطبيق المفتوح فقط، لتمنع التطبيقات التي اخترتها. لا تقرأ محتوى الشاشة.',
      'App protection learns only the name of the app that opened, to stop the apps you chose. It doesn\'t read screen content.',
    ),
    SetupCheckId.notifications => tr(
      'يُستخدم لتنبيه واحد فقط: عندما تتوقف الحماية أو تضعف. لا إعلانات ولا رسائل أخرى. بدونه يظهر الانقطاع عند فتح التطبيق فقط.',
      'Used for one alert only: when protection stops or weakens. No ads or other messages. Without it, interruptions show only when you open the app.',
    ),
    SetupCheckId.battery => tr(
      'بعض الأجهزة (خصوصًا بعض الشركات المصنعة) توقف التطبيقات في الخلفية بقوة. الاستثناء من تحسين البطارية يقلل انقطاع الحماية.',
      'Some devices (especially some manufacturers) aggressively stop background apps. Exempting SafeGuard from battery optimisation reduces interruptions.',
    ),
    SetupCheckId.alwaysOn => tr(
      'الطريقة الأكثر موثوقية ليعمل SafeGuard بعد إعادة تشغيل الجهاز. لا يستطيع التطبيق قراءة هذا الإعداد، لذلك لا نعرضه كمفعّل.',
      "The most reliable way for SafeGuard to start after a device restart. Apps can't read this setting, so we never show it as on.",
    ),
  };

  String get dependsOn => switch (this) {
    SetupCheckId.vpnConsent ||
    SetupCheckId.protectionRunning ||
    SetupCheckId.otherVpn => tr(
      'فلترة DNS، البحث الآمن، قوائم الحظر والسماح',
      'DNS filtering, SafeSearch, block and allow lists',
    ),
    SetupCheckId.privateDns => tr(
      'فلترة DNS والبحث الآمن',
      'DNS filtering and SafeSearch',
    ),
    SetupCheckId.accessibility => tr(
      'حماية التطبيقات فقط',
      'App protection only',
    ),
    SetupCheckId.notifications => tr(
      'تنبيه توقف الحماية',
      'The protection-stopped alert',
    ),
    SetupCheckId.battery => tr(
      'استمرار الحماية في الخلفية',
      'Protection staying on in the background',
    ),
    SetupCheckId.alwaysOn => tr(
      'بدء الحماية بعد إعادة التشغيل',
      'Protection starting after a restart',
    ),
  };

  String get howTo => switch (this) {
    SetupCheckId.vpnConsent => tr(
      'اضغط «منح الموافقة» ثم «موافق» في نافذة Android.',
      'Tap “Grant consent”, then “OK” in the Android dialog.',
    ),
    SetupCheckId.protectionRunning => tr(
      'اضغط «تشغيل الحماية».',
      'Tap “Start protection”.',
    ),
    SetupCheckId.otherVpn => tr(
      'افصل تطبيق VPN الآخر من إعدادات VPN، ثم شغّل الحماية.',
      'Disconnect the other VPN app in VPN settings, then start protection.',
    ),
    SetupCheckId.privateDns => tr(
      'الإعدادات ← الشبكة والإنترنت ← DNS الخاص ← «تلقائي» أو «إيقاف».',
      'Settings → Network & internet → Private DNS → “Automatic” or “Off”.',
    ),
    SetupCheckId.accessibility => tr(
      'افتح «حماية التطبيقات» واتبع الإفصاح، ثم فعّل SafeGuard في إعدادات تسهيل الاستخدام.',
      'Open App protection, read the disclosure, then turn on SafeGuard in Accessibility settings.',
    ),
    SetupCheckId.notifications => tr(
      'اضغط «السماح بالإشعارات» ثم «سماح» في نافذة Android.',
      'Tap “Allow notifications”, then “Allow” in the Android dialog.',
    ),
    SetupCheckId.battery => tr(
      'في القائمة التي تفتح: «كل التطبيقات» ← SafeGuard ← «عدم التحسين». الأسماء تختلف حسب الجهاز.',
      'In the list that opens: “All apps” → SafeGuard → “Don’t optimise”. Names vary by device.',
    ),
    SetupCheckId.alwaysOn => tr(
      'إعدادات VPN ← SafeGuard ← فعّل «VPN دائم التشغيل».',
      'VPN settings → SafeGuard → turn on “Always-on VPN”.',
    ),
  };
}

String checkActionLabel(CheckAction a) => switch (a) {
  CheckAction.grantVpn => tr('منح الموافقة', 'Grant consent'),
  CheckAction.startProtection => tr('تشغيل الحماية', 'Start protection'),
  CheckAction.openVpnSettings => tr('إعدادات VPN', 'VPN settings'),
  CheckAction.openPrivateDnsSettings => tr(
    'إعدادات الشبكة',
    'Network settings',
  ),
  CheckAction.openAppProtection => tr('حماية التطبيقات', 'App protection'),
  CheckAction.openBatterySettings => tr('إعدادات البطارية', 'Battery settings'),
  CheckAction.requestNotifications => tr(
    'السماح بالإشعارات',
    'Allow notifications',
  ),
};

(String, SgStatus) checkStatusLabel(CheckStatus s) => switch (s) {
  CheckStatus.ok => (tr('جاهز', 'Ready'), SgStatus.active),
  CheckStatus.missing => (tr('مطلوب', 'Required'), SgStatus.error),
  CheckStatus.recommended => (tr('موصى به', 'Recommended'), SgStatus.paused),
  CheckStatus.notNeeded => (
    tr('غير مطلوب', 'Not needed'),
    SgStatus.unavailable,
  ),
  CheckStatus.unknown => (tr('غير معروف', 'Unknown'), SgStatus.unavailable),
};

/// PROTECTED / PARTIALLY PROTECTED / NOT PROTECTED, from native health.
(String, String, Color) overallLabel(BuildContext context, OverallHealth o) {
  final c = context.colors;
  return switch (o) {
    OverallHealth.protected => (
      tr('محمي', 'PROTECTED'),
      tr(
        'كل الطبقات التي فعّلتها تعمل الآن.',
        'Every layer you turned on is working now.',
      ),
      c.accent,
    ),
    OverallHealth.partiallyProtected => (
      tr('محمي جزئيًا', 'PARTIALLY PROTECTED'),
      tr(
        'الحماية تعمل لكن طبقة أو أكثر تحتاج انتباهك.',
        'Protection runs, but one or more layers need attention.',
      ),
      c.warning,
    ),
    OverallHealth.notProtected => (
      tr('غير محمي', 'NOT PROTECTED'),
      tr('لا تتم فلترة الشبكة الآن.', 'Network filtering isn\'t running now.'),
      c.danger,
    ),
    OverallHealth.unknown => (
      tr('غير معروف', 'UNKNOWN'),
      tr(
        'لا يمكن قراءة الحالة على هذا الجهاز.',
        "The status can't be read on this device.",
      ),
      c.textTertiary,
    ),
  };
}

/// Large overall-status card.
class OverallStatusCard extends StatelessWidget {
  const OverallStatusCard({super.key, required this.overall});
  final OverallHealth overall;

  @override
  Widget build(BuildContext context) {
    final (label, detail, tone) = overallLabel(context, overall);
    return SgCard(
      borderColor: tone.withValues(alpha: 0.5),
      child: Row(
        children: [
          StatusDot(color: tone, size: 14),
          const SizedBox(width: SgSpace.x3),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: context.text.titleLarge!.copyWith(color: tone),
                  ),
                  const SizedBox(height: SgSpace.x1),
                  Text(detail, style: context.text.bodySmall),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One check: status, why, what depends on it, how to fix, and an action.
class SetupCheckCard extends StatelessWidget {
  const SetupCheckCard({
    super.key,
    required this.check,
    required this.onAction,
  });

  final SetupCheck check;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (label, status) = checkStatusLabel(check.status);
    Widget line(String head, String body) => Padding(
      padding: const EdgeInsets.only(top: SgSpace.x2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$head: ',
              style: context.text.labelMedium!.copyWith(color: c.textSecondary),
            ),
            TextSpan(text: body),
          ],
        ),
        style: context.text.bodySmall,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: SgSpace.x3),
      child: SgCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(check.id.title, style: context.text.titleMedium),
                ),
                const SizedBox(width: SgSpace.x2),
                StatusIndicator(status: status, label: label, dense: true),
              ],
            ),
            line(tr('لماذا', 'Why'), check.id.why),
            line(tr('يعتمد عليه', 'Needed for'), check.id.dependsOn),
            if (check.needsAttention)
              line(tr('الطريقة', 'How'), check.id.howTo),
            if (check.action != null && onAction != null) ...[
              const SizedBox(height: SgSpace.x3),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: SecondaryButton(
                  label: checkActionLabel(check.action!),
                  onPressed: onAction,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
