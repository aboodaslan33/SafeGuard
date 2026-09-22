import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/utils/arabic_format.dart';
import '../../protection/domain/protection.dart';

/// What is actually enforced right now, layer by layer, and what can't be.
class StatusScreen extends StatelessWidget {
  const StatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([deps.protection, deps.settings]),
      builder: (context, _) {
        final state = deps.protection.state;
        final engine = deps.protection.engineStatus;
        final stats = deps.protection.stats;
        final appLock = deps.settings.settings.appLockEnabled;
        final searchOn =
            state.enabled && state.isActive(ProtectionCategory.unsafeSearch);

        final (SgStatus engineStatus, String engineLabel) = switch (engine) {
          EngineStatus.running => (SgStatus.active, 'تعمل'),
          EngineStatus.stopped => (SgStatus.paused, 'متوقفة'),
          EngineStatus.notInstalled => (SgStatus.unavailable, 'غير متاحة بعد'),
        };

        return SgPage(
          title: 'الحالة',
          subtitle: 'ما يعمل الآن على هذا الجهاز',
          children: [
            const SizedBox(height: SgSpace.x6),
            _Summary(state: state),
            const SectionHeader(title: 'طبقات الحماية'),
            SgGroupedCard(
              children: [
                _LayerRow(
                  icon: Icons.rule_rounded,
                  title: 'سياسة الحماية',
                  subtitle:
                      '${state.activeCount} من '
                      '${ProtectionCategory.values.length} فئات محددة',
                  status: state.enabled ? SgStatus.active : SgStatus.paused,
                  label: state.enabled ? 'مفعّلة' : 'متوقفة',
                ),
                _LayerRow(
                  icon: Icons.dns_outlined,
                  title: 'فلترة الشبكة (DNS)',
                  subtitle: 'حجب النطاقات قبل تحميلها',
                  status: engineStatus,
                  label: engineLabel,
                ),
                _LayerRow(
                  icon: Icons.manage_search_rounded,
                  title: 'البحث الآمن',
                  subtitle: 'Google وBing وYouTube',
                  status: !searchOn
                      ? SgStatus.paused
                      : engine == EngineStatus.running
                      ? SgStatus.active
                      : SgStatus.unavailable,
                  label: !searchOn
                      ? 'متوقف'
                      : engine == EngineStatus.running
                      ? 'مفعّل'
                      : 'بانتظار الشبكة',
                ),
                _LayerRow(
                  icon: Icons.lock_outline_rounded,
                  title: 'قفل التطبيق',
                  subtitle: 'رمز PIN عند فتح SafeGuard',
                  status: appLock ? SgStatus.active : SgStatus.paused,
                  label: appLock ? 'مفعّل' : 'معطّل',
                ),
              ],
            ),
            const SectionHeader(title: 'المحتوى المحجوب'),
            _StatsRow(stats: stats),
            const SizedBox(height: SgSpace.x3),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
              child: Text(
                stats.isAvailable
                    ? 'تُحسب على جهازك فقط ولا تُرسل إلى أي جهة.'
                    : 'تظهر الإحصاءات بعد تفعيل فلترة الشبكة. '
                          'تُحسب على جهازك فقط ولا تُرسل إلى أي جهة.',
                style: context.text.bodySmall!.copyWith(
                  color: context.colors.textTertiary,
                ),
              ),
            ),
            const SectionHeader(title: 'حدود الحماية'),
            const _Limitations(),
          ],
        );
      },
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.state});

  final ProtectionState state;

  @override
  Widget build(BuildContext context) {
    final updated = state.updatedAt;
    return SgCard(
      child: Row(
        children: [
          ShieldMark(
            size: 32,
            muted: !state.enabled,
            color: state.enabled ? null : context.colors.warning,
          ),
          const SizedBox(width: SgSpace.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.enabled ? 'الحماية مفعّلة' : 'الحماية متوقفة',
                  style: context.text.titleLarge,
                ),
                Text(
                  updated == null
                      ? 'الإعدادات الافتراضية'
                      : 'آخر تغيير ${ArabicFormat.relative(updated)}',
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LayerRow extends StatelessWidget {
  const _LayerRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.label,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final SgStatus status;
  final String label;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SgSpace.x4,
          vertical: SgSpace.x3,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // On narrow rows (small phones, large text) the status moves under
            // the title instead of squeezing it.
            final stacked = constraints.maxWidth < 330;
            final pill = StatusIndicator(
              status: status,
              label: label,
              dense: true,
            );
            return Row(
              children: [
                SgIconWell(icon: icon),
                const SizedBox(width: SgSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.text.titleMedium),
                      Text(subtitle, style: context.text.bodySmall),
                      if (stacked) ...[
                        const SizedBox(height: SgSpace.x2),
                        pill,
                      ],
                    ],
                  ),
                ),
                if (!stacked) ...[const SizedBox(width: SgSpace.x2), pill],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats});

  final ProtectionStats stats;

  @override
  Widget build(BuildContext context) {
    return SgCard(
      padding: const EdgeInsets.symmetric(vertical: SgSpace.x4),
      child: IntrinsicHeight(
        child: Row(
          children: [
            _Stat(label: 'اليوم', value: stats.today),
            VerticalDivider(color: context.colors.border, width: 1),
            _Stat(label: 'هذا الأسبوع', value: stats.thisWeek),
            VerticalDivider(color: context.colors.border, width: 1),
            _Stat(label: 'الإجمالي', value: stats.total),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final int? value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Semantics(
        label: '$label: ${value ?? 'غير متاح'}',
        excludeSemantics: true,
        child: Column(
          children: [
            Text(
              value?.toString() ?? '—',
              style: context.text.headlineSmall!.copyWith(
                color: value == null ? c.textTertiary : c.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(label, style: context.text.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _Limitations extends StatelessWidget {
  const _Limitations();

  static const _points = [
    'Android لا يسمح لأي تطبيق بقراءة محتوى التطبيقات الأخرى. '
        'الحجب يتم على مستوى النطاقات، لا على مستوى الصور أو المنشورات داخل التطبيق.',
    'المتصفحات أو التطبيقات التي تستخدم DNS مشفّرًا خاصًا بها، أو شبكة VPN أخرى، '
        'قد تتجاوز الفلترة.',
    'يستطيع مالك الجهاز إزالة التطبيق أو مسح بياناته من إعدادات Android.',
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SgCard(
      child: Column(
        children: [
          for (var i = 0; i < _points.length; i++) ...[
            if (i > 0) const SizedBox(height: SgSpace.x3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: StatusDot(color: c.textTertiary, size: 5),
                ),
                const SizedBox(width: SgSpace.x3),
                Expanded(
                  child: Text(_points[i], style: context.text.bodyMedium),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
