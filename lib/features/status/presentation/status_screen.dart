import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/utils/arabic_format.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_controller.dart';
import '../../protection/presentation/protection_ui.dart';

/// What is actually enforced right now, layer by layer, what was blocked,
/// and what can't be blocked.
class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final protection = AppScope.of(context).protection;
      protection.refreshStatus();
      protection.refreshStats();
    });
  }

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([deps.protection, deps.settings]),
      builder: (context, _) {
        final protection = deps.protection;
        final state = protection.state;
        final snap = protection.snapshot;
        final stats = protection.stats;
        final appLock = deps.settings.settings.appLockEnabled;
        final supported = snap.isSupported;

        final (SgStatus vpnStatus, String vpnLabel) = switch (snap.vpnState) {
          VpnState.running => (SgStatus.active, 'يعمل'),
          VpnState.starting => (SgStatus.unavailable, 'يبدأ'),
          VpnState.stopping => (SgStatus.unavailable, 'يتوقف'),
          VpnState.stopped => (SgStatus.paused, 'متوقف'),
          VpnState.permissionRequired => (SgStatus.error, 'بلا موافقة'),
          VpnState.revoked => (SgStatus.error, 'مفصول'),
          VpnState.error => (SgStatus.error, 'خطأ'),
          VpnState.unsupported => (SgStatus.unavailable, 'غير متاح'),
        };

        return SgPage(
          title: 'الحالة',
          subtitle: 'ما يعمل الآن على هذا الجهاز',
          children: [
            const SizedBox(height: SgSpace.x6),
            _Summary(health: protection.health, state: state),
            EngineWarnings(snapshot: snap),
            const SectionHeader(title: 'طبقات الحماية'),
            SgGroupedCard(
              children: [
                _LayerRow(
                  icon: Icons.vpn_key_outlined,
                  title: 'VPN محلي',
                  subtitle: 'على الجهاز فقط، دون أي خادم',
                  status: vpnStatus,
                  label: vpnLabel,
                ),
                _LayerRow(
                  icon: Icons.dns_outlined,
                  title: 'فلتر DNS',
                  subtitle: 'فحص أسماء النطاقات قبل الاتصال',
                  status: snap.dnsFilterActive
                      ? SgStatus.active
                      : supported
                      ? SgStatus.paused
                      : SgStatus.unavailable,
                  label: snap.dnsFilterActive
                      ? 'يعمل'
                      : supported
                      ? 'متوقف'
                      : 'غير متاح',
                ),
                _LayerRow(
                  icon: Icons.rule_rounded,
                  title: 'القواعد',
                  subtitle: supported
                      ? '${ArabicFormat.count(snap.blockingRuleCount, 'قاعدة حظر', 'قاعدتا حظر', 'قواعد حظر')} · '
                            '${state.activeNetworkCount} فئات مفعّلة'
                      : '${state.activeNetworkCount} فئات مفعّلة',
                  status: !supported
                      ? SgStatus.unavailable
                      : snap.rulesReady
                      ? SgStatus.active
                      : SgStatus.paused,
                  label: !supported
                      ? 'غير متاحة'
                      : snap.rulesReady
                      ? 'محمّلة'
                      : 'غير محمّلة',
                ),
                _LayerRow(
                  icon: Icons.manage_search_rounded,
                  title: 'حماية البحث',
                  subtitle: 'البحث الآمن في Google وBing وYouTube',
                  status: !protection.searchProtectionEnabled
                      ? SgStatus.paused
                      : snap.isActive
                      ? SgStatus.active
                      : SgStatus.unavailable,
                  label: !protection.searchProtectionEnabled
                      ? 'متوقفة'
                      : snap.isActive
                      ? 'مفعّلة'
                      : 'بانتظار VPN',
                ),
                _LayerRow(
                  icon: Icons.apps_rounded,
                  title: 'حماية التطبيقات',
                  subtitle: 'عبر خدمة تسهيل الاستخدام',
                  status: switch (protection.accessibility) {
                    AccessibilityStatus.enabled => SgStatus.active,
                    AccessibilityStatus.disabled ||
                    AccessibilityStatus.permissionDenied => SgStatus.paused,
                    AccessibilityStatus.unavailable => SgStatus.error,
                    AccessibilityStatus.unsupported => SgStatus.unavailable,
                  },
                  label: switch (protection.accessibility) {
                    AccessibilityStatus.enabled => 'مفعّلة',
                    AccessibilityStatus.disabled => 'غير مفعّلة',
                    AccessibilityStatus.permissionDenied => 'مرفوضة',
                    AccessibilityStatus.unavailable ||
                    AccessibilityStatus.unsupported => 'غير متاحة',
                  },
                ),
                _LayerRow(
                  icon: Icons.auto_awesome_outlined,
                  title: 'الحماية الذكية',
                  subtitle: protection.aiSettings.imageModelAvailable
                      ? 'تصنيف النص والصور على الجهاز'
                      : 'تصنيف النص على الجهاز · لا نموذج صور',
                  status: !supported
                      ? SgStatus.unavailable
                      : !protection.aiSettings.enabled || !state.enabled
                      ? SgStatus.paused
                      : protection.aiSettings.textModelAvailable
                      ? SgStatus.active
                      : SgStatus.error,
                  label: !supported
                      ? 'غير متاحة'
                      : !protection.aiSettings.enabled || !state.enabled
                      ? 'متوقفة'
                      : protection.aiSettings.textModelAvailable
                      ? 'مفعّلة'
                      : 'النموذج غير متاح',
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
            SectionHeader(
              title: 'المحتوى المحجوب',
              trailing: supported
                  ? TextButton(
                      onPressed: () => context.push(Routes.activity),
                      child: const Text('السجل'),
                    )
                  : null,
            ),
            _StatsRow(stats: stats),
            if (stats.byCategory.isNotEmpty) ...[
              const SizedBox(height: SgSpace.x3),
              _CategoryBreakdown(stats: stats),
            ],
            const SizedBox(height: SgSpace.x3),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
              child: Text(
                stats.isAvailable
                    ? 'تكرار الطلب للنطاق نفسه خلال 30 ثانية يُحتسب مرة واحدة. '
                          'تُحسب على جهازك فقط ولا تُرسل إلى أي جهة.'
                    : 'تظهر الإحصاءات عندما تعمل فلترة الشبكة. '
                          'تُحسب على جهازك فقط ولا تُرسل إلى أي جهة.',
                style: context.text.bodySmall!.copyWith(
                  color: context.colors.textTertiary,
                ),
              ),
            ),
            if (supported) ...[
              const SectionHeader(title: 'بعد إعادة تشغيل الجهاز'),
              SgGroupedCard(
                children: [
                  SecuritySettingTile(
                    icon: Icons.restart_alt_rounded,
                    title: 'VPN الدائم',
                    subtitle:
                        'فعّل «VPN دائم التشغيل» لـ SafeGuard في إعدادات Android '
                        'ليعمل تلقائيًا بعد إعادة التشغيل.',
                    onTap: protection.engine.openVpnSettings,
                  ),
                ],
              ),
            ],
            const SectionHeader(title: 'حدود الحماية'),
            const _Limitations(),
          ],
        );
      },
    );
  }
}

class _CategoryBreakdown extends StatelessWidget {
  const _CategoryBreakdown({required this.stats});

  final ProtectionStats stats;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entries = stats.byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final max = entries.first.value.clamp(1, 1 << 30);
    return SgCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('حسب الفئة · آخر 30 يومًا', style: context.text.labelSmall),
          const SizedBox(height: SgSpace.x3),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: SgSpace.x3),
              child: Row(
                children: [
                  SizedBox(
                    width: 104,
                    child: Text(
                      e.key.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall,
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: SgRadius.pillAll,
                      child: LinearProgressIndicator(
                        value: e.value / max,
                        minHeight: 6,
                        backgroundColor: c.surfaceSunken,
                        color: c.accent,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${e.value}',
                      textAlign: TextAlign.end,
                      style: context.text.labelMedium!.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.health, required this.state});

  final ProtectionHealth health;
  final ProtectionState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final updated = state.updatedAt;
    final (String title, Color tone) = switch (health) {
      ProtectionHealth.active => ('الحماية نشطة', c.accent),
      ProtectionHealth.transitioning => ('جارٍ التشغيل', c.info),
      ProtectionHealth.inactive => ('الحماية غير نشطة', c.danger),
      ProtectionHealth.paused => ('الحماية متوقفة', c.warning),
      ProtectionHealth.suspended => ('الحماية متوقفة مؤقتًا', c.warning),
      ProtectionHealth.partial => ('الحماية مفعّلة جزئيًا', c.warning),
      ProtectionHealth.unsupported => ('الفلترة غير متاحة', c.info),
    };
    return SgCard(
      child: Row(
        children: [
          ShieldMark(
            size: 32,
            muted: health != ProtectionHealth.active,
            color: tone,
          ),
          const SizedBox(width: SgSpace.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleLarge),
                Text(
                  updated == null
                      ? 'الإعدادات الافتراضية'
                      : 'آخر تغيير للإعدادات ${ArabicFormat.relative(updated)}',
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
            final stacked = constraints.maxWidth < 300;
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
            _Stat(label: 'آخر 7 أيام', value: stats.last7Days),
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
    'Android لا يسمح لأي تطبيق بقراءة محتوى التطبيقات الأخرى. الحجب يتم على '
        'مستوى أسماء النطاقات، لا على مستوى الصور أو المنشورات أو الصفحات.',
    'المتصفحات والتطبيقات التي تستخدم DNS مشفّرًا خاصًا بها (DNS over HTTPS '
        'أو DNS over TLS) أو خوادم DNS مثبتة في الكود قد تتجاوز الفلترة.',
    'ميزة «DNS الخاص» في Android عند ضبطها على مزوّد محدد تتجاوز فلترة '
        'SafeGuard.',
    'يعمل تطبيق VPN واحد فقط في الوقت نفسه. تشغيل VPN آخر يوقف SafeGuard.',
    'يستطيع مالك الجهاز فصل VPN أو إزالة التطبيق أو مسح بياناته من إعدادات Android.',
    'فحص البحث يشمل ما تبحث عنه عبر SafeGuard فقط؛ لا يقرأ SafeGuard ما تكتبه في التطبيقات الأخرى.',
    'حماية التطبيقات تمنع فتح التطبيق كاملًا، ولا تستطيع فلترة المحتوى داخله.',
    'داخل إنستغرام وتيك توك وغيرها لا يستطيع SafeGuard فلترة المنشورات (تأتي من '
        'نفس خوادم التطبيق). استخدم إعداد «المحتوى الحساس ← أقل» داخل إنستغرام، '
        'أو احمِ التطبيق كاملًا من «حماية التطبيقات».',
    'قوائم النطاقات المضمّنة (مقامرة، جنسي، مخدرات) كبيرة لكنها ليست كاملة، '
        'وقد تحجب موقعًا سليمًا أحيانًا؛ أضفه إلى النطاقات المسموحة.',
    'الحماية الذكية تعمل على الجهاز وعند الطلب فقط (بحث SafeGuard والصور التي '
        'تختار فحصها). نموذج النص صغير ومحدود الدقة، ولا يوجد نموذج صور في هذا الإصدار.',
    'لا يرسل SafeGuard إشعارات؛ انقطاع الحماية (فصل VPN، سحب الموافقة، إيقاف '
        'خدمة التطبيقات) يظهر عند فتح التطبيق.',
    'بعد إعادة تشغيل الجهاز قد يمنع النظام بدء الحماية تلقائيًا؛ الطريقة '
        'الموثوقة هي «VPN دائم التشغيل» في إعدادات Android.',
    'وضع الأمان والإيقاف المؤقت يوقفان الفلترة عمدًا، ويظهران هنا كـ«غير محمي».',
    'SafeGuard طبقات حماية متعددة، ولا يضمن حجب 100% من المحتوى.',
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
