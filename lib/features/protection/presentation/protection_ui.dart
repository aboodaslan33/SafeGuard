import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../domain/protection.dart';
import 'protection_controller.dart';
import 'protection_guard.dart';

/// Presentation metadata for each category (kept out of the domain layer).
extension ProtectionCategoryUi on ProtectionCategory {
  String get title => switch (this) {
    ProtectionCategory.sexual => 'المحتوى الجنسي',
    ProtectionCategory.violence => 'المحتوى العنيف',
    ProtectionCategory.gore => 'المحتوى الدموي',
    ProtectionCategory.gambling => 'المقامرة',
    ProtectionCategory.drugs => 'المخدرات',
    ProtectionCategory.dangerous => 'المحتوى الخطِر',
    ProtectionCategory.unsafeSearch => 'فلترة البحث',
  };

  String get description => switch (this) {
    ProtectionCategory.sexual => 'المواقع الإباحية والمحتوى الصريح',
    ProtectionCategory.violence => 'مشاهد الإيذاء والعنف الجسدي',
    ProtectionCategory.gore => 'الصور والمقاطع الصادمة',
    ProtectionCategory.gambling => 'الكازينوهات ومواقع المراهنات',
    ProtectionCategory.drugs => 'الترويج للمخدرات وبيعها',
    ProtectionCategory.dangerous => 'إيذاء النفس والتحديات الخطرة',
    ProtectionCategory.unsafeSearch => 'البحث الآمن في Google وBing وYouTube',
  };

  IconData get icon => switch (this) {
    ProtectionCategory.sexual => Icons.eighteen_up_rating_outlined,
    ProtectionCategory.violence => Icons.back_hand_outlined,
    ProtectionCategory.gore => Icons.water_drop_outlined,
    ProtectionCategory.gambling => Icons.casino_outlined,
    ProtectionCategory.drugs => Icons.medication_outlined,
    ProtectionCategory.dangerous => Icons.report_outlined,
    ProtectionCategory.unsafeSearch => Icons.manage_search_rounded,
  };
}

/// User-initiated protection changes. Loosening protection (turning it
/// off, or disabling a category) always requires the PIN; tightening never
/// does.
abstract final class ProtectionActions {
  static Future<void> setEnabled(BuildContext context, bool enabled) async {
    final protection = AppScope.of(context).protection;
    if (!enabled) {
      if (!await ProtectionGuard.authorize(
        context,
        loosens: true,
        reason: 'لإيقاف الحماية على هذا الجهاز',
      )) {
        return;
      }
    } else if (!context.mounted || !await ensureVpnConsent(context)) {
      return;
    }
    final result = await protection.setEnabled(enabled);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  /// "Start again" when protection is on but the VPN isn't running.
  static Future<void> restart(BuildContext context) async {
    final protection = AppScope.of(context).protection;
    if (!await ensureVpnConsent(context)) return;
    final result = await protection.startEngine();
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  /// Explains the local VPN, then shows Android's own consent dialog.
  /// Returns true if consent exists (or the platform has no engine).
  static Future<bool> ensureVpnConsent(BuildContext context) async {
    final engine = AppScope.of(context).protection.engine;
    if (!engine.isSupported) return true;
    try {
      if (await engine.hasVpnPermission()) return true;
      if (!context.mounted) return false;
      final proceed = await showSgBottomSheet<bool>(
        context,
        title: 'اتصال VPN محلي',
        builder: (context) => const _VpnConsentExplainer(),
      );
      if (proceed != true) return false;
      final granted = await engine.requestVpnPermission();
      if (!granted && context.mounted) {
        showSgSnack(context, 'لم تُمنح موافقة VPN، لذلك لم تُشغَّل الحماية.');
      }
      return granted;
    } catch (e) {
      if (context.mounted) showSgSnack(context, 'تعذّر طلب إذن VPN.');
      return false;
    }
  }

  static Future<void> setCategory(
    BuildContext context,
    ProtectionCategory category,
    bool active,
  ) async {
    final protection = AppScope.of(context).protection;
    if (!await ProtectionGuard.authorize(
      context,
      loosens: !active,
      reason: active
          ? 'لتعديل الفئات (إعدادات الحماية مقفلة)'
          : 'لإيقاف فلترة «${category.title}»',
    )) {
      return;
    }
    final result = await protection.setCategory(category, active);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  /// NORMAL → STRICT is free (unless locked); every other change needs the PIN.
  static Future<void> setMode(BuildContext context, ProtectionMode mode) async {
    final protection = AppScope.of(context).protection;
    final from = protection.state.mode;
    if (from == mode) return;
    if (!await ProtectionGuard.authorize(
      context,
      loosens: ProtectionMode.changeNeedsPin(from, mode),
      reason: 'لتغيير وضع الحماية',
    )) {
      return;
    }
    final result = await protection.setMode(mode);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }
}

class _VpnConsentExplainer extends StatelessWidget {
  const _VpnConsentExplainer();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: SgSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: c.accent),
          const SizedBox(width: SgSpace.x3),
          Expanded(child: Text(text, style: context.text.bodyMedium)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'يحتاج SafeGuard إلى إنشاء اتصال VPN محلي حتى يستطيع فلترة طلبات '
          'DNS وحظر النطاقات المصنفة ضمن الفئات التي اخترتها.',
          style: context.text.bodyLarge,
        ),
        const SizedBox(height: SgSpace.x5),
        point(
          Icons.phone_android_rounded,
          'الاتصال يعمل داخل جهازك فقط، ولا يمر عبر أي خادم.',
        ),
        point(
          Icons.dns_outlined,
          'يرى أسماء النطاقات فقط، لا محتوى الصفحات ولا كلمات المرور ولا الرسائل.',
        ),
        point(
          Icons.verified_user_outlined,
          'سيعرض Android نافذة موافقة رسمية. يمكنك إيقاف الاتصال من إعدادات النظام في أي وقت.',
        ),
        const SizedBox(height: SgSpace.x4),
        PrimaryButton(
          label: 'تفعيل الحماية',
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: SgSpace.x2),
        SgTextButton(
          label: 'ليس الآن',
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }
}

/// Hero card on Home: the real state of protection, the layers behind it,
/// and the one action that changes it.
class ProtectionStatusCard extends StatelessWidget {
  const ProtectionStatusCard({
    super.key,
    required this.health,
    required this.state,
    required this.snapshot,
    required this.onToggle,
    required this.onRestart,
    this.report = HealthReport.unknown,
    this.pauseRemaining = Duration.zero,
    this.onEndPause,
  });

  final ProtectionHealth health;
  final HealthReport report;
  final Duration pauseRemaining;
  final VoidCallback? onEndPause;
  final ProtectionState state;
  final EngineSnapshot snapshot;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (
      Color tone,
      Color wash,
      SgStatus status,
      String pill,
      String title,
    ) = switch (health) {
      ProtectionHealth.active => (
        c.accent,
        c.accentMuted,
        SgStatus.active,
        'نشطة',
        'الحماية نشطة',
      ),
      ProtectionHealth.transitioning => (
        c.info,
        c.infoMuted,
        SgStatus.unavailable,
        'جارٍ التشغيل',
        'جارٍ تشغيل الحماية',
      ),
      ProtectionHealth.inactive => (
        c.danger,
        c.dangerMuted,
        SgStatus.error,
        'غير نشطة',
        'الحماية غير نشطة',
      ),
      ProtectionHealth.paused => (
        c.warning,
        c.warningMuted,
        SgStatus.paused,
        'متوقفة',
        'الحماية متوقفة',
      ),
      ProtectionHealth.suspended => (
        c.warning,
        c.warningMuted,
        SgStatus.paused,
        report.safeMode ? 'وضع الأمان' : 'إيقاف مؤقت',
        report.safeMode ? 'وضع الأمان مفعّل' : 'الحماية متوقفة مؤقتًا',
      ),
      ProtectionHealth.partial => (
        c.warning,
        c.warningMuted,
        SgStatus.paused,
        'جزئية',
        'الحماية مفعّلة جزئيًا',
      ),
      ProtectionHealth.unsupported => (
        c.info,
        c.infoMuted,
        SgStatus.unavailable,
        'غير متاحة',
        'الفلترة غير متاحة هنا',
      ),
    };

    final summary = switch (health) {
      ProtectionHealth.active =>
        'يتم فحص طلبات DNS على هذا الجهاز وحجب الفئات المحددة.',
      ProtectionHealth.transitioning => 'لحظات…',
      ProtectionHealth.inactive => _inactiveReason(snapshot),
      ProtectionHealth.paused => 'لا يتم حجب أي محتوى حاليًا.',
      ProtectionHealth.suspended =>
        report.safeMode
            ? 'الفلترة متوقفة لاستعادة الاتصال بالإنترنت. أعد تفعيل الحماية عندما تكون جاهزًا.'
            : 'لا يتم حجب أي محتوى. تُستأنف الحماية تلقائيًا بعد ${formatCountdown(pauseRemaining)}.',
      ProtectionHealth.partial => partialReason(report),
      ProtectionHealth.unsupported =>
        'فلترة الشبكة تعمل على أجهزة Android فقط.',
    };

    return AnimatedContainer(
      duration: SgMotion.slow,
      curve: SgMotion.standard,
      decoration: BoxDecoration(
        borderRadius: SgRadius.xlAll,
        border: Border.all(color: tone.withValues(alpha: 0.3)),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [wash, c.surface],
          stops: const [0, 0.75],
        ),
        boxShadow: SgElevation.raised(dark: context.isDark),
      ),
      padding: const EdgeInsets.all(SgSpace.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusIndicator(status: status, label: pill),
                    const SizedBox(height: SgSpace.x4),
                    Semantics(
                      liveRegion: true,
                      child: Text(title, style: context.text.headlineSmall),
                    ),
                    const SizedBox(height: SgSpace.x1),
                    Text(summary, style: context.text.bodyMedium),
                  ],
                ),
              ),
              const SizedBox(width: SgSpace.x4),
              ShieldMark(
                size: 52,
                color: tone,
                muted: health != ProtectionHealth.active,
              ),
            ],
          ),
          if (health == ProtectionHealth.active ||
              health == ProtectionHealth.partial) ...[
            const SizedBox(height: SgSpace.x5),
            _LayerGrid(snapshot: snapshot, state: state),
          ],
          const SizedBox(height: SgSpace.x5),
          _action(),
        ],
      ),
    );
  }

  Widget _action() {
    return switch (health) {
      ProtectionHealth.active ||
      ProtectionHealth.partial ||
      ProtectionHealth.transitioning => SecondaryButton(
        label: 'إيقاف الحماية',
        icon: Icons.pause_rounded,
        onPressed: health == ProtectionHealth.transitioning
            ? null
            : () => onToggle(false),
      ),
      ProtectionHealth.suspended =>
        report.safeMode
            ? PrimaryButton(
                label: 'إعادة تفعيل الحماية',
                icon: Icons.shield_outlined,
                onPressed: onRestart,
              )
            : PrimaryButton(
                label: 'استئناف الحماية الآن',
                icon: Icons.play_arrow_rounded,
                onPressed: onEndPause,
              ),
      ProtectionHealth.inactive => PrimaryButton(
        label: 'تشغيل الحماية',
        icon: Icons.play_arrow_rounded,
        onPressed: onRestart,
      ),
      ProtectionHealth.paused => PrimaryButton(
        label: 'تفعيل الحماية',
        icon: Icons.shield_outlined,
        onPressed: () => onToggle(true),
      ),
      ProtectionHealth.unsupported => const SizedBox.shrink(),
    };
  }

  static String _inactiveReason(EngineSnapshot s) {
    if (s.otherVpnActive) {
      return 'توقف اتصال VPN الخاص بـ SafeGuard لأن تطبيق VPN آخر يعمل.';
    }
    return switch (s.vpnState) {
      VpnState.permissionRequired =>
        'موافقة VPN غير ممنوحة. شغّل الحماية لإعادة طلبها.',
      VpnState.revoked =>
        'فُصل اتصال VPN من إعدادات النظام أو من تطبيق VPN آخر.',
      VpnState.error => 'تعذّر تشغيل VPN. حاول مجددًا.',
      _ => 'اتصال VPN متوقف، ولا يتم حجب أي نطاق الآن.',
    };
  }
}

/// VPN / DNS / Rules / Categories, as compact labelled cells.
class _LayerGrid extends StatelessWidget {
  const _LayerGrid({required this.snapshot, required this.state});

  final EngineSnapshot snapshot;
  final ProtectionState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget cell(String label, String value, bool ok) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: context.text.labelSmall),
          const SizedBox(height: 2),
          Row(
            children: [
              StatusDot(color: ok ? c.accent : c.warning, size: 6),
              const SizedBox(width: SgSpace.x1),
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
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SgSpace.x4,
        vertical: SgSpace.x3,
      ),
      decoration: BoxDecoration(
        color: c.surfaceSunken.withValues(alpha: 0.6),
        borderRadius: SgRadius.mdAll,
      ),
      child: Row(
        children: [
          cell('VPN', 'يعمل', snapshot.vpnState == VpnState.running),
          cell('فلتر DNS', 'يعمل', snapshot.dnsFilterActive),
          cell(
            'القواعد',
            snapshot.blockingRuleCount > 0 ? 'محمّلة' : 'بلا قوائم',
            snapshot.blockingRuleCount > 0,
          ),
          cell(
            'الفئات',
            '${state.activeNetworkCount} مفعّلة',
            state.activeNetworkCount > 0,
          ),
        ],
      ),
    );
  }
}

/// Conditions outside SafeGuard's control that weaken protection. Shown
/// only when they apply; never alarming, always specific.
class EngineWarnings extends StatelessWidget {
  const EngineWarnings({
    super.key,
    required this.snapshot,
    this.onOpenVpnSettings,
  });

  final EngineSnapshot snapshot;
  final VoidCallback? onOpenVpnSettings;

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String)>[
      if (snapshot.otherVpnActive)
        (
          Icons.vpn_lock_outlined,
          'يوجد VPN آخر نشط وقد يمنع SafeGuard من العمل. '
              'يمكن تشغيل تطبيق VPN واحد فقط في الوقت نفسه على Android.',
        ),
      if (snapshot.privateDnsStrict)
        (
          Icons.dns_outlined,
          'ميزة «DNS الخاص» في Android مضبوطة على مزوّد محدد، وقد تتجاوز '
              'فلترة SafeGuard. اضبطها على «تلقائي» أو «إيقاف» لحماية كاملة.',
        ),
      if (snapshot.isActive && snapshot.blockingRuleCount == 0)
        (
          Icons.playlist_remove_rounded,
          'لا توجد قوائم حظر مثبتة للفئات بعد. الحظر يعمل الآن على النطاقات '
              'التي تضيفها بنفسك فقط.',
        ),
      if (snapshot.isActive && !snapshot.upstreamAvailable)
        (
          Icons.wifi_off_rounded,
          'لا يوجد اتصال بالشبكة. الحظر مستمر، والمواقع الأخرى ستعمل عند عودة الاتصال.',
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: SgSpace.x3),
      child: Column(
        children: [
          for (final (icon, text) in items)
            Padding(
              padding: const EdgeInsets.only(bottom: SgSpace.x2),
              child: SgCard(
                color: c.warningMuted,
                borderColor: Colors.transparent,
                radius: SgRadius.mdAll,
                padding: const EdgeInsets.symmetric(
                  horizontal: SgSpace.x4,
                  vertical: SgSpace.x3,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20, color: c.warning),
                    const SizedBox(width: SgSpace.x3),
                    Expanded(
                      child: Text(
                        text,
                        style: context.text.bodySmall!.copyWith(
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One category row with its switch.
class CategoryTile extends StatelessWidget {
  const CategoryTile({
    super.key,
    required this.category,
    required this.active,
    required this.enabled,
    required this.onChanged,
    this.comingSoon = false,
  });

  final ProtectionCategory category;
  final bool active;

  /// Category exists but isn't enforced yet: no switch, a "قريبًا" pill.
  final bool comingSoon;

  /// False while global protection is off: the row is shown but inert.
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lit = active && enabled && !comingSoon;
    return AnimatedOpacity(
      duration: SgMotion.medium,
      opacity: enabled && !comingSoon ? 1 : 0.5,
      child: MergeSemantics(
        child: InkWell(
          onTap: enabled && !comingSoon ? () => onChanged(!active) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SgSpace.x4,
              vertical: SgSpace.x3,
            ),
            child: Row(
              children: [
                SgIconWell(
                  icon: category.icon,
                  foreground: lit ? c.accent : c.textTertiary,
                  background: lit ? c.accentMuted : c.surfaceSunken,
                ),
                const SizedBox(width: SgSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(category.title, style: context.text.titleMedium),
                      Text(
                        category.description,
                        style: context.text.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: SgSpace.x2),
                if (comingSoon)
                  const StatusIndicator(
                    status: SgStatus.unavailable,
                    label: 'قريبًا',
                    dense: true,
                  )
                else
                  Switch(value: active, onChanged: enabled ? onChanged : null),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "4:05" style countdown (minutes:seconds).
String formatCountdown(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Why protection is only partial, from the native health reason
/// (`<layer>:<reason>`).
String partialReason(HealthReport r) => switch (r.reason?.split(':').last) {
  'private_dns' => 'ميزة «DNS الخاص» في Android تتجاوز الفلترة. اضبطها على «تلقائي» أو «إيقاف».',
  'upstream_failing' =>
    'خادم DNS في شبكتك لا يستجيب. إذا انقطع الإنترنت استخدم «وضع الأمان».',
  'no_blocking_rules' =>
    'لا توجد قوائم حظر للنطاقات بعد؛ يعمل الحظر على قوائمك وكلماتك فقط.',
  'model_unavailable' => 'نموذج الحماية الذكية غير متاح؛ القواعد تعمل.',
  'database_error' => 'تعذّرت قراءة قاعدة البيانات المحلية.',
  final other when other != null && other.startsWith('accessibility') =>
    'لديك تطبيقات محمية لكن خدمة حماية التطبيقات غير مفعّلة.',
  _ => 'إحدى طبقات الحماية لا تعمل كما يجب. راجع شاشة الحالة.',
};

/// Short Arabic label for one layer's state.
String layerStateLabel(LayerState s) => switch (s) {
  LayerState.active => 'يعمل',
  LayerState.degraded => 'جزئي',
  LayerState.inactive => 'متوقف',
  LayerState.off => 'مطفأ',
  LayerState.notConfigured => 'غير مُعد',
};

String modeLabel(ProtectionMode m) => switch (m) {
  ProtectionMode.normal => 'عادي',
  ProtectionMode.strict => 'صارم',
  ProtectionMode.custom => 'مخصص',
};
