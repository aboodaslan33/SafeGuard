import 'package:flutter/material.dart';

import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_controller.dart';
import '../../protection/presentation/protection_ui.dart';

/// "Protection interrupted": something the user didn't ask for stopped a
/// layer (VPN revoked, failed, consent withdrawn, accessibility off, boot
/// start refused). Offers the one fix SafeGuard may legitimately try.
class InterruptionBanner extends StatelessWidget {
  const InterruptionBanner({
    super.key,
    required this.report,
    required this.onRestart,
    required this.onDismiss,
  });

  final HealthReport report;
  final VoidCallback onRestart;
  final VoidCallback onDismiss;

  static String describe(IncidentKind k) => switch (k) {
    IncidentKind.vpnRevoked => tr(
      'فُصل اتصال VPN الخاص بـ SafeGuard (من إعدادات النظام أو بسبب VPN آخر).',
      "SafeGuard's VPN connection was disconnected (from system settings or by another VPN).",
    ),
    IncidentKind.vpnFailed => tr(
      'توقّف فلتر الحماية بسبب خطأ ولم تنجح محاولات الاستعادة التلقائية.',
      "The protection filter stopped because of an error and automatic recovery didn't succeed.",
    ),
    IncidentKind.permissionRevoked => tr(
      'سُحبت موافقة VPN من SafeGuard.',
      "SafeGuard's VPN consent was revoked.",
    ),
    IncidentKind.accessibilityDisabled => tr(
      'أُوقفت خدمة حماية التطبيقات في إعدادات تسهيل الاستخدام.',
      'The app protection service was turned off in Accessibility settings.',
    ),
    IncidentKind.bootStartFailed => tr(
      'لم يسمح النظام بتشغيل الحماية تلقائيًا بعد إعادة تشغيل الجهاز.',
      "The system didn't allow protection to start automatically after the device restarted.",
    ),
    IncidentKind.recovered => tr(
      'استُعيدت الحماية تلقائيًا بعد خطأ.',
      'Protection was restored automatically after an error.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    if (!report.interrupted) return const SizedBox.shrink();
    final c = context.colors;
    final latest = report.incidents.last;
    return Padding(
      padding: const EdgeInsets.only(top: SgSpace.x3),
      child: SgCard(
        color: c.dangerMuted,
        borderColor: Colors.transparent,
        radius: SgRadius.mdAll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: c.danger),
                const SizedBox(width: SgSpace.x2),
                Expanded(
                  child: Text(
                    tr('انقطعت الحماية', 'Protection was interrupted'),
                    style: context.text.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: SgSpace.x2),
            Text(describe(latest.kind), style: context.text.bodyMedium),
            if (report.incidents.length > 1)
              Text(
                tr(
                  'و${report.incidents.length - 1} انقطاع آخر منذ آخر مراجعة.',
                  'and ${report.incidents.length - 1} more interruption(s) since the last review.',
                ),
                style: context.text.bodySmall,
              ),
            const SizedBox(height: SgSpace.x3),
            Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    label: tr('أعد تفعيل الحماية', 'Turn protection back on'),
                    onPressed: onRestart,
                  ),
                ),
                const SizedBox(width: SgSpace.x2),
                SgTextButton(label: tr('تم', 'Done'), onPressed: onDismiss),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Mode picker: NORMAL / STRICT / CUSTOM, with a one-line explanation.
class ModeSelector extends StatelessWidget {
  const ModeSelector({super.key, required this.mode, required this.onChanged});

  final ProtectionMode mode;
  final ValueChanged<ProtectionMode>? onChanged;

  static String explain(ProtectionMode m) => switch (m) {
    ProtectionMode.normal => tr(
      'كل الفئات، والحظر عند الثقة العالية فقط لتقليل الأخطاء.',
      'All categories, blocking only at high confidence to reduce mistakes.',
    ),
    ProtectionMode.strict => tr(
      'كل الفئات بحدود أشد: يحظر أكثر، وقد يحظر محتوى سليمًا.',
      'All categories with stricter thresholds: blocks more, and may block harmless content.',
    ),
    ProtectionMode.custom => tr(
      'تختار بنفسك الفئات والبحث والحماية الذكية.',
      'You choose categories, search and AI protection yourself.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final change = onChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<ProtectionMode>(
          segments: [
            for (final m in ProtectionMode.values)
              ButtonSegment(value: m, label: Text(modeLabel(m))),
          ],
          selected: {mode},
          showSelectedIcon: false,
          onSelectionChanged: change == null ? null : (s) => change(s.first),
        ),
        const SizedBox(height: SgSpace.x2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
          child: Text(explain(mode), style: context.text.bodySmall),
        ),
      ],
    );
  }
}

/// Compact status of every layer + key numbers.
class DashboardPanel extends StatelessWidget {
  const DashboardPanel({super.key, required this.protection});

  final ProtectionController protection;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = protection.healthReport;
    final (String overall, Color tone) = switch (r.overall) {
      OverallHealth.protected => (
        tr('محمي بالكامل', 'Fully protected'),
        c.accent,
      ),
      OverallHealth.partiallyProtected => (
        tr('محمي جزئيًا', 'Partially protected'),
        c.warning,
      ),
      OverallHealth.notProtected => (tr('غير محمي', 'Not protected'), c.danger),
      OverallHealth.unknown => (tr('غير معروف', 'Unknown'), c.textTertiary),
    };
    String layer(HealthLayer l) {
      final h = r.layer(l);
      return h == null ? '—' : layerStateLabel(h.state);
    }

    Color tint(HealthLayer l) => switch (r.layer(l)?.state) {
      LayerState.active => c.accent,
      LayerState.degraded => c.warning,
      LayerState.inactive => c.danger,
      _ => c.textTertiary,
    };

    Widget row(String label, String value, [Color? dot]) => Padding(
      padding: const EdgeInsets.symmetric(vertical: SgSpace.x1),
      child: Row(
        children: [
          Expanded(child: Text(label, style: context.text.bodyMedium)),
          if (dot != null) ...[
            StatusDot(color: dot, size: 7),
            const SizedBox(width: SgSpace.x2),
          ],
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelMedium,
            ),
          ),
        ],
      ),
    );

    final today = protection.stats.today;
    return SgCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              StatusDot(color: tone, size: 10),
              const SizedBox(width: SgSpace.x2),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(overall, style: context.text.titleMedium),
                ),
              ),
            ],
          ),
          const Divider(height: SgSpace.x5),
          row(tr('الوضع', 'Mode'), modeLabel(protection.state.mode)),
          row('VPN', layer(HealthLayer.vpn), tint(HealthLayer.vpn)),
          row('DNS', layer(HealthLayer.dns), tint(HealthLayer.dns)),
          row(
            tr('البحث', 'Search'),
            layer(HealthLayer.search),
            tint(HealthLayer.search),
          ),
          row(
            tr('الذكاء الاصطناعي', 'AI'),
            layer(HealthLayer.ai),
            tint(HealthLayer.ai),
          ),
          row(
            tr('التطبيقات المحمية', 'Protected apps'),
            '${protection.protectedAppCount}',
          ),
          row(
            tr('المحجوب اليوم', 'Blocked today'),
            today == null ? '—' : '$today',
          ),
        ],
      ),
    );
  }
}
