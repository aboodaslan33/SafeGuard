import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
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
          VpnState.running => (SgStatus.active, tr('يعمل', 'Running')),
          VpnState.starting => (SgStatus.unavailable, tr('يبدأ', 'Starting')),
          VpnState.stopping => (SgStatus.unavailable, tr('يتوقف', 'Stopping')),
          VpnState.stopped => (SgStatus.paused, tr('متوقف', 'Stopped')),
          VpnState.permissionRequired => (
            SgStatus.error,
            tr('بلا موافقة', 'No consent'),
          ),
          VpnState.revoked => (SgStatus.error, tr('مفصول', 'Disconnected')),
          VpnState.error => (SgStatus.error, tr('خطأ', 'Error')),
          VpnState.unsupported => (
            SgStatus.unavailable,
            tr('غير متاح', 'Unavailable'),
          ),
        };

        return SgPage(
          title: tr('الحالة', 'Status'),
          subtitle: tr(
            'ما يعمل الآن على هذا الجهاز',
            "What's running on this device now",
          ),
          children: [
            const SizedBox(height: SgSpace.x6),
            _Summary(health: protection.health, state: state),
            EngineWarnings(snapshot: snap),
            SectionHeader(title: tr('طبقات الحماية', 'Protection layers')),
            SgGroupedCard(
              children: [
                _LayerRow(
                  icon: Icons.vpn_key_outlined,
                  title: tr('VPN محلي', 'Local VPN'),
                  subtitle: tr(
                    'على الجهاز فقط، دون أي خادم',
                    'On the device only, no server',
                  ),
                  status: vpnStatus,
                  label: vpnLabel,
                ),
                _LayerRow(
                  icon: Icons.dns_outlined,
                  title: tr('فلتر DNS', 'DNS filter'),
                  subtitle: tr(
                    'فحص أسماء النطاقات قبل الاتصال',
                    'Checks domain names before connecting',
                  ),
                  status: snap.dnsFilterActive
                      ? SgStatus.active
                      : supported
                      ? SgStatus.paused
                      : SgStatus.unavailable,
                  label: snap.dnsFilterActive
                      ? tr('يعمل', 'Running')
                      : supported
                      ? tr('متوقف', 'Stopped')
                      : tr('غير متاح', 'Unavailable'),
                ),
                _LayerRow(
                  icon: Icons.rule_rounded,
                  title: tr('القواعد', 'Rules'),
                  subtitle: supported
                      ? tr(
                          '${ArabicFormat.count(snap.blockingRuleCount, 'قاعدة حظر', 'قاعدتا حظر', 'قواعد حظر')} · '
                              '${state.activeNetworkCount} فئات مفعّلة',
                          '${snap.blockingRuleCount} blocking rules · ${state.activeNetworkCount} categories on',
                        )
                      : tr(
                          '${state.activeNetworkCount} فئات مفعّلة',
                          '${state.activeNetworkCount} categories on',
                        ),
                  status: !supported
                      ? SgStatus.unavailable
                      : snap.rulesReady
                      ? SgStatus.active
                      : SgStatus.paused,
                  label: !supported
                      ? tr('غير متاحة', 'Unavailable')
                      : snap.rulesReady
                      ? tr('محمّلة', 'Loaded')
                      : tr('غير محمّلة', 'Not loaded'),
                ),
                _LayerRow(
                  icon: Icons.manage_search_rounded,
                  title: tr('حماية البحث', 'Search protection'),
                  subtitle: tr(
                    'البحث الآمن في Google وBing وYouTube',
                    'SafeSearch on Google, Bing and YouTube',
                  ),
                  status: !protection.searchProtectionEnabled
                      ? SgStatus.paused
                      : snap.isActive
                      ? SgStatus.active
                      : SgStatus.unavailable,
                  label: !protection.searchProtectionEnabled
                      ? tr('متوقفة', 'Off')
                      : snap.isActive
                      ? tr('مفعّلة', 'On')
                      : tr('بانتظار VPN', 'Waiting for VPN'),
                ),
                _LayerRow(
                  icon: Icons.apps_rounded,
                  title: tr('حماية التطبيقات', 'App protection'),
                  subtitle: tr(
                    'عبر خدمة تسهيل الاستخدام',
                    'Through the Accessibility service',
                  ),
                  status: switch (protection.accessibility) {
                    AccessibilityStatus.enabled => SgStatus.active,
                    AccessibilityStatus.disabled ||
                    AccessibilityStatus.permissionDenied => SgStatus.paused,
                    AccessibilityStatus.unavailable => SgStatus.error,
                    AccessibilityStatus.unsupported => SgStatus.unavailable,
                  },
                  label: switch (protection.accessibility) {
                    AccessibilityStatus.enabled => tr('مفعّلة', 'On'),
                    AccessibilityStatus.disabled => tr('غير مفعّلة', 'Off'),
                    AccessibilityStatus.permissionDenied => tr(
                      'مرفوضة',
                      'Declined',
                    ),
                    AccessibilityStatus.unavailable ||
                    AccessibilityStatus.unsupported => tr(
                      'غير متاحة',
                      'Unavailable',
                    ),
                  },
                ),
                _LayerRow(
                  icon: Icons.auto_awesome_outlined,
                  title: tr('الحماية الذكية', 'AI protection'),
                  subtitle: protection.aiSettings.imageModelAvailable
                      ? tr(
                          'تصنيف النص والصور على الجهاز',
                          'On-device text and image classification',
                        )
                      : tr(
                          'تصنيف النص على الجهاز · لا نموذج صور',
                          'On-device text classification · no image model',
                        ),
                  status: !supported
                      ? SgStatus.unavailable
                      : !protection.aiSettings.enabled || !state.enabled
                      ? SgStatus.paused
                      : protection.aiSettings.textModelAvailable
                      ? SgStatus.active
                      : SgStatus.error,
                  label: !supported
                      ? tr('غير متاحة', 'Unavailable')
                      : !protection.aiSettings.enabled || !state.enabled
                      ? tr('متوقفة', 'Off')
                      : protection.aiSettings.textModelAvailable
                      ? tr('مفعّلة', 'On')
                      : tr('النموذج غير متاح', 'Model unavailable'),
                ),
                _LayerRow(
                  icon: Icons.lock_outline_rounded,
                  title: tr('قفل التطبيق', 'App lock'),
                  subtitle: tr(
                    'رمز PIN عند فتح SafeGuard',
                    'PIN when opening SafeGuard',
                  ),
                  status: appLock ? SgStatus.active : SgStatus.paused,
                  label: appLock ? tr('مفعّل', 'On') : tr('معطّل', 'Off'),
                ),
              ],
            ),
            SectionHeader(
              title: tr('المحتوى المحجوب', 'Blocked content'),
              trailing: supported
                  ? TextButton(
                      onPressed: () => context.push(Routes.activity),
                      child: Text(tr('السجل', 'Log')),
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
                    ? tr(
                        'تكرار الطلب للنطاق نفسه خلال 30 ثانية يُحتسب مرة واحدة. '
                            'تُحسب على جهازك فقط ولا تُرسل إلى أي جهة.',
                        'Repeated requests for the same domain within 30 seconds count once. Computed on your device only and never sent anywhere.',
                      )
                    : tr(
                        'تظهر الإحصاءات عندما تعمل فلترة الشبكة. '
                            'تُحسب على جهازك فقط ولا تُرسل إلى أي جهة.',
                        'Statistics appear when network filtering is running. Computed on your device only and never sent anywhere.',
                      ),
                style: context.text.bodySmall!.copyWith(
                  color: context.colors.textTertiary,
                ),
              ),
            ),
            if (supported) ...[
              SectionHeader(
                title: tr('بعد إعادة تشغيل الجهاز', 'After a device restart'),
              ),
              SgGroupedCard(
                children: [
                  SecuritySettingTile(
                    icon: Icons.restart_alt_rounded,
                    title: tr('VPN الدائم', 'Always-on VPN'),
                    subtitle: tr(
                      'فعّل «VPN دائم التشغيل» لـ SafeGuard في إعدادات Android '
                          'ليعمل تلقائيًا بعد إعادة التشغيل.',
                      'Turn on “Always-on VPN” for SafeGuard in Android settings so it starts automatically after a restart.',
                    ),
                    onTap: protection.engine.openVpnSettings,
                  ),
                ],
              ),
            ],
            SectionHeader(title: tr('حدود الحماية', 'Protection limits')),
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
          Text(
            tr('حسب الفئة · آخر 30 يومًا', 'By category · last 30 days'),
            style: context.text.labelSmall,
          ),
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
      ProtectionHealth.active => (
        tr('الحماية نشطة', 'Protection is active'),
        c.accent,
      ),
      ProtectionHealth.transitioning => (
        tr('جارٍ التشغيل', 'Starting'),
        c.info,
      ),
      ProtectionHealth.inactive => (
        tr('الحماية غير نشطة', 'Protection is inactive'),
        c.danger,
      ),
      ProtectionHealth.paused => (
        tr('الحماية متوقفة', 'Protection is off'),
        c.warning,
      ),
      ProtectionHealth.suspended => (
        tr('الحماية متوقفة مؤقتًا', 'Protection is paused'),
        c.warning,
      ),
      ProtectionHealth.partial => (
        tr('الحماية مفعّلة جزئيًا', 'Protection is partially on'),
        c.warning,
      ),
      ProtectionHealth.unsupported => (
        tr('الفلترة غير متاحة', 'Filtering unavailable'),
        c.info,
      ),
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
                      ? tr('الإعدادات الافتراضية', 'Default settings')
                      : tr(
                          'آخر تغيير للإعدادات ${ArabicFormat.relative(updated)}',
                          'Settings last changed ${ArabicFormat.relative(updated)}',
                        ),
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
            _Stat(label: tr('اليوم', 'Today'), value: stats.today),
            VerticalDivider(color: context.colors.border, width: 1),
            _Stat(
              label: tr('آخر 7 أيام', 'Last 7 days'),
              value: stats.last7Days,
            ),
            VerticalDivider(color: context.colors.border, width: 1),
            _Stat(label: tr('الإجمالي', 'Total'), value: stats.total),
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
        label: tr(
          '$label: ${value ?? 'غير متاح'}',
          "$label: ${value ?? 'unavailable'}",
        ),
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

  static List<String> get _points => [
    tr(
      'Android لا يسمح لأي تطبيق بقراءة محتوى التطبيقات الأخرى. الحجب يتم على '
          'مستوى أسماء النطاقات، لا على مستوى الصور أو المنشورات أو الصفحات.',
      "Android doesn't let any app read other apps' content. Blocking happens at the domain-name level, not at the level of images, posts or pages.",
    ),
    tr(
      'المتصفحات والتطبيقات التي تستخدم DNS مشفّرًا خاصًا بها (DNS over HTTPS '
          'أو DNS over TLS) أو خوادم DNS مثبتة في الكود قد تتجاوز الفلترة.',
      'Browsers and apps that use their own encrypted DNS (DNS over HTTPS or DNS over TLS) or hard-coded DNS servers may bypass filtering.',
    ),
    tr(
      'ميزة «DNS الخاص» في Android عند ضبطها على مزوّد محدد تتجاوز فلترة '
          'SafeGuard.',
      "Android's “Private DNS”, when set to a specific provider, bypasses SafeGuard's filtering.",
    ),
    tr(
      'يعمل تطبيق VPN واحد فقط في الوقت نفسه. تشغيل VPN آخر يوقف SafeGuard.',
      'Only one VPN app runs at a time. Starting another VPN stops SafeGuard.',
    ),
    tr(
      'يستطيع مالك الجهاز فصل VPN أو إزالة التطبيق أو مسح بياناته من إعدادات Android.',
      'The device owner can disconnect the VPN, uninstall the app or clear its data from Android settings.',
    ),
    tr(
      'فحص البحث يشمل ما تبحث عنه عبر SafeGuard فقط؛ لا يقرأ SafeGuard ما تكتبه في التطبيقات الأخرى.',
      "Search checks cover only what you search for through SafeGuard; SafeGuard doesn't read what you type in other apps.",
    ),
    tr(
      'حماية التطبيقات تمنع فتح التطبيق كاملًا، ولا تستطيع فلترة المحتوى داخله.',
      "App protection stops the whole app from opening; it can't filter content inside it.",
    ),
    tr(
      'داخل إنستغرام وتيك توك وغيرها لا يستطيع SafeGuard فلترة المنشورات (تأتي من '
          'نفس خوادم التطبيق). استخدم إعداد «المحتوى الحساس ← أقل» داخل إنستغرام، '
          'أو احمِ التطبيق كاملًا من «حماية التطبيقات».',
      "Inside Instagram, TikTok and similar apps, SafeGuard can't filter posts (they come from the app's own servers). Use Instagram's “Sensitive content → Less” setting, or protect the whole app in App protection.",
    ),
    tr(
      'قوائم النطاقات المضمّنة (مقامرة، جنسي، مخدرات) كبيرة لكنها ليست كاملة، '
          'وقد تحجب موقعًا سليمًا أحيانًا؛ أضفه إلى النطاقات المسموحة.',
      'The bundled domain lists (gambling, sexual, drugs) are large but not complete, and may occasionally block a harmless site; add it to the allowed domains.',
    ),
    tr(
      'الحماية الذكية تعمل على الجهاز وعند الطلب فقط (بحث SafeGuard والصور التي '
          'تختار فحصها). نموذج النص صغير ومحدود الدقة، ولا يوجد نموذج صور في هذا الإصدار.',
      "AI protection runs on the device and on demand only (SafeGuard search and images you choose to check). The text model is small with limited accuracy, and there's no image model in this version.",
    ),
    tr(
      'لا يرسل SafeGuard إشعارات؛ انقطاع الحماية (فصل VPN، سحب الموافقة، إيقاف '
          'خدمة التطبيقات) يظهر عند فتح التطبيق.',
      "SafeGuard doesn't send notifications; protection interruptions (VPN disconnected, consent revoked, app service turned off) are shown when you open the app.",
    ),
    tr(
      'بعد إعادة تشغيل الجهاز قد يمنع النظام بدء الحماية تلقائيًا؛ الطريقة '
          'الموثوقة هي «VPN دائم التشغيل» في إعدادات Android.',
      'After a device restart the system may prevent protection from starting automatically; the reliable way is “Always-on VPN” in Android settings.',
    ),
    tr(
      'وضع الأمان والإيقاف المؤقت يوقفان الفلترة عمدًا، ويظهران هنا كـ«غير محمي».',
      'Safe Mode and pause stop filtering on purpose, and appear here as “Not protected”.',
    ),
    tr(
      'SafeGuard طبقات حماية متعددة، ولا يضمن حجب 100% من المحتوى.',
      "SafeGuard is a multi-layer protection system and doesn't guarantee blocking 100% of content.",
    ),
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
