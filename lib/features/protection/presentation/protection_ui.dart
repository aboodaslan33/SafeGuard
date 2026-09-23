import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../../../core/i18n/i18n.dart';
import '../domain/protection.dart';
import 'protection_controller.dart';
import 'protection_guard.dart';

/// Presentation metadata for each category (kept out of the domain layer).
extension ProtectionCategoryUi on ProtectionCategory {
  String get title => switch (this) {
    ProtectionCategory.sexual => tr('المحتوى الجنسي', 'Sexual content'),
    ProtectionCategory.violence => tr('المحتوى العنيف', 'Violent content'),
    ProtectionCategory.gore => tr('المحتوى الدموي', 'Gore'),
    ProtectionCategory.gambling => tr('المقامرة', 'Gambling'),
    ProtectionCategory.drugs => tr('المخدرات', 'Drugs'),
    ProtectionCategory.dangerous => tr('المحتوى الخطِر', 'Dangerous content'),
    ProtectionCategory.unsafeSearch => tr('فلترة البحث', 'Search filtering'),
  };

  String get description => switch (this) {
    ProtectionCategory.sexual => tr(
      'المواقع الإباحية والمحتوى الصريح',
      'Pornographic sites and explicit content',
    ),
    ProtectionCategory.violence => tr(
      'مشاهد الإيذاء والعنف الجسدي',
      'Scenes of harm and physical violence',
    ),
    ProtectionCategory.gore => tr(
      'الصور والمقاطع الصادمة',
      'Shocking images and videos',
    ),
    ProtectionCategory.gambling => tr(
      'الكازينوهات ومواقع المراهنات',
      'Casinos and betting sites',
    ),
    ProtectionCategory.drugs => tr(
      'الترويج للمخدرات وبيعها',
      'Promotion and sale of drugs',
    ),
    ProtectionCategory.dangerous => tr(
      'إيذاء النفس والتحديات الخطرة',
      'Self-harm and dangerous challenges',
    ),
    ProtectionCategory.unsafeSearch => tr(
      'البحث الآمن في Google وBing وYouTube',
      'SafeSearch on Google, Bing and YouTube',
    ),
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
        reason: tr(
          'لإيقاف الحماية على هذا الجهاز',
          'to stop protection on this device',
        ),
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
        title: tr('اتصال VPN محلي', 'Local VPN connection'),
        builder: (context) => const _VpnConsentExplainer(),
      );
      if (proceed != true) return false;
      final granted = await engine.requestVpnPermission();
      if (!granted && context.mounted) {
        showSgSnack(
          context,
          tr(
            'لم تُمنح موافقة VPN، لذلك لم تُشغَّل الحماية.',
            "VPN consent wasn't granted, so protection didn't start.",
          ),
        );
      }
      return granted;
    } catch (e) {
      if (context.mounted) {
        showSgSnack(
          context,
          tr('تعذّر طلب إذن VPN.', "Couldn't request VPN permission."),
        );
      }
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
          ? tr(
              'لتعديل الفئات (إعدادات الحماية مقفلة)',
              'to change categories (protection settings are locked)',
            )
          : tr(
              'لإيقاف فلترة «${category.title}»',
              'to stop filtering “${category.title}”',
            ),
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
      reason: tr('لتغيير وضع الحماية', 'to change the protection mode'),
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
          tr(
            'يحتاج SafeGuard إلى إنشاء اتصال VPN محلي حتى يستطيع فلترة طلبات '
                'DNS وحظر النطاقات المصنفة ضمن الفئات التي اخترتها.',
            'SafeGuard needs to create a local VPN connection so it can filter DNS requests and block domains in the categories you chose.',
          ),
          style: context.text.bodyLarge,
        ),
        const SizedBox(height: SgSpace.x5),
        point(
          Icons.phone_android_rounded,
          tr(
            'الاتصال يعمل داخل جهازك فقط، ولا يمر عبر أي خادم.',
            "The connection runs inside your device only and doesn't pass through any server.",
          ),
        ),
        point(
          Icons.dns_outlined,
          tr(
            'يرى أسماء النطاقات فقط، لا محتوى الصفحات ولا كلمات المرور ولا الرسائل.',
            'It sees domain names only — not page content, passwords or messages.',
          ),
        ),
        point(
          Icons.verified_user_outlined,
          tr(
            'سيعرض Android نافذة موافقة رسمية. يمكنك إيقاف الاتصال من إعدادات النظام في أي وقت.',
            'Android will show an official consent dialog. You can stop the connection from system settings at any time.',
          ),
        ),
        const SizedBox(height: SgSpace.x4),
        PrimaryButton(
          label: tr('تفعيل الحماية', 'Turn on protection'),
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: SgSpace.x2),
        SgTextButton(
          label: tr('ليس الآن', 'Not now'),
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
        tr('نشطة', 'Active'),
        tr('الحماية نشطة', 'Protection is active'),
      ),
      ProtectionHealth.transitioning => (
        c.info,
        c.infoMuted,
        SgStatus.unavailable,
        tr('جارٍ التشغيل', 'Starting'),
        tr('جارٍ تشغيل الحماية', 'Starting protection'),
      ),
      ProtectionHealth.inactive => (
        c.danger,
        c.dangerMuted,
        SgStatus.error,
        tr('غير نشطة', 'Inactive'),
        tr('الحماية غير نشطة', 'Protection is inactive'),
      ),
      ProtectionHealth.paused => (
        c.warning,
        c.warningMuted,
        SgStatus.paused,
        tr('متوقفة', 'Off'),
        tr('الحماية متوقفة', 'Protection is off'),
      ),
      ProtectionHealth.suspended => (
        c.warning,
        c.warningMuted,
        SgStatus.paused,
        report.safeMode
            ? tr('وضع الأمان', 'Safe Mode')
            : tr('إيقاف مؤقت', 'Paused'),
        report.safeMode
            ? tr('وضع الأمان مفعّل', 'Safe Mode is on')
            : tr('الحماية متوقفة مؤقتًا', 'Protection is paused'),
      ),
      ProtectionHealth.partial => (
        c.warning,
        c.warningMuted,
        SgStatus.paused,
        tr('جزئية', 'Partial'),
        tr('الحماية مفعّلة جزئيًا', 'Protection is partially on'),
      ),
      ProtectionHealth.unsupported => (
        c.info,
        c.infoMuted,
        SgStatus.unavailable,
        tr('غير متاحة', 'Unavailable'),
        tr('الفلترة غير متاحة هنا', "Filtering isn't available here"),
      ),
    };

    final summary = switch (health) {
      ProtectionHealth.active => tr(
        'يتم فحص طلبات DNS على هذا الجهاز وحجب الفئات المحددة.',
        'DNS requests on this device are checked and the selected categories are blocked.',
      ),
      ProtectionHealth.transitioning => tr('لحظات…', 'One moment…'),
      ProtectionHealth.inactive => _inactiveReason(snapshot),
      ProtectionHealth.paused => tr(
        'لا يتم حجب أي محتوى حاليًا.',
        'No content is being blocked right now.',
      ),
      ProtectionHealth.suspended =>
        report.safeMode
            ? tr(
                'الفلترة متوقفة لاستعادة الاتصال بالإنترنت. أعد تفعيل الحماية عندما تكون جاهزًا.',
                "Filtering is stopped to restore internet access. Turn protection back on when you're ready.",
              )
            : tr(
                'لا يتم حجب أي محتوى. تُستأنف الحماية تلقائيًا بعد ${formatCountdown(pauseRemaining)}.',
                'No content is being blocked. Protection resumes automatically in ${formatCountdown(pauseRemaining)}.',
              ),
      ProtectionHealth.partial => partialReason(report),
      ProtectionHealth.unsupported => tr(
        'فلترة الشبكة تعمل على أجهزة Android فقط.',
        'Network filtering works on Android devices only.',
      ),
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
        label: tr('إيقاف الحماية', 'Stop protection'),
        icon: Icons.pause_rounded,
        onPressed: health == ProtectionHealth.transitioning
            ? null
            : () => onToggle(false),
      ),
      ProtectionHealth.suspended =>
        report.safeMode
            ? PrimaryButton(
                label: tr('إعادة تفعيل الحماية', 'Turn protection back on'),
                icon: Icons.shield_outlined,
                onPressed: onRestart,
              )
            : PrimaryButton(
                label: tr('استئناف الحماية الآن', 'Resume protection now'),
                icon: Icons.play_arrow_rounded,
                onPressed: onEndPause,
              ),
      ProtectionHealth.inactive => PrimaryButton(
        label: tr('تشغيل الحماية', 'Start protection'),
        icon: Icons.play_arrow_rounded,
        onPressed: onRestart,
      ),
      ProtectionHealth.paused => PrimaryButton(
        label: tr('تفعيل الحماية', 'Turn on protection'),
        icon: Icons.shield_outlined,
        onPressed: () => onToggle(true),
      ),
      ProtectionHealth.unsupported => const SizedBox.shrink(),
    };
  }

  static String _inactiveReason(EngineSnapshot s) {
    if (s.otherVpnActive) {
      return tr(
        'توقف اتصال VPN الخاص بـ SafeGuard لأن تطبيق VPN آخر يعمل.',
        "SafeGuard's VPN connection stopped because another VPN app is running.",
      );
    }
    return switch (s.vpnState) {
      VpnState.permissionRequired => tr(
        'موافقة VPN غير ممنوحة. شغّل الحماية لإعادة طلبها.',
        "VPN consent isn't granted. Start protection to request it again.",
      ),
      VpnState.revoked => tr(
        'فُصل اتصال VPN من إعدادات النظام أو من تطبيق VPN آخر.',
        'The VPN connection was disconnected from system settings or by another VPN app.',
      ),
      VpnState.error => tr(
        'تعذّر تشغيل VPN. حاول مجددًا.',
        "Couldn't start the VPN. Try again.",
      ),
      _ => tr(
        'اتصال VPN متوقف، ولا يتم حجب أي نطاق الآن.',
        'The VPN connection is stopped, and no domains are being blocked now.',
      ),
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
          cell(
            'VPN',
            tr('يعمل', 'Running'),
            snapshot.vpnState == VpnState.running,
          ),
          cell(
            tr('فلتر DNS', 'DNS filter'),
            tr('يعمل', 'Running'),
            snapshot.dnsFilterActive,
          ),
          cell(
            tr('القواعد', 'Rules'),
            snapshot.blockingRuleCount > 0
                ? tr('محمّلة', 'Loaded')
                : tr('بلا قوائم', 'No lists'),
            snapshot.blockingRuleCount > 0,
          ),
          cell(
            tr('الفئات', 'Categories'),
            tr(
              '${state.activeNetworkCount} مفعّلة',
              '${state.activeNetworkCount} on',
            ),
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
          tr(
            'يوجد VPN آخر نشط وقد يمنع SafeGuard من العمل. '
                'يمكن تشغيل تطبيق VPN واحد فقط في الوقت نفسه على Android.',
            'Another VPN is active and may stop SafeGuard from working. Android runs only one VPN app at a time.',
          ),
        ),
      if (snapshot.privateDnsStrict)
        (
          Icons.dns_outlined,
          tr(
            'ميزة «DNS الخاص» في Android مضبوطة على مزوّد محدد، وقد تتجاوز '
                'فلترة SafeGuard. اضبطها على «تلقائي» أو «إيقاف» لحماية كاملة.',
            "Android's “Private DNS” is set to a specific provider and may bypass SafeGuard's filtering. Set it to “Automatic” or “Off” for full protection.",
          ),
        ),
      if (snapshot.isActive && snapshot.blockingRuleCount == 0)
        (
          Icons.playlist_remove_rounded,
          tr(
            'لا توجد قوائم حظر مثبتة للفئات بعد. الحظر يعمل الآن على النطاقات '
                'التي تضيفها بنفسك فقط.',
            'No category block lists are installed yet. Blocking currently works only on domains you add yourself.',
          ),
        ),
      if (snapshot.isActive && !snapshot.upstreamAvailable)
        (
          Icons.wifi_off_rounded,
          tr(
            'لا يوجد اتصال بالشبكة. الحظر مستمر، والمواقع الأخرى ستعمل عند عودة الاتصال.',
            'No network connection. Blocking continues, and other sites will work when the connection returns.',
          ),
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
                  StatusIndicator(
                    status: SgStatus.unavailable,
                    label: tr('قريبًا', 'Coming soon'),
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
  'private_dns' => tr(
    'ميزة «DNS الخاص» في Android تتجاوز الفلترة. اضبطها على «تلقائي» أو «إيقاف».',
    "Android's “Private DNS” bypasses filtering. Set it to “Automatic” or “Off”.",
  ),
  'upstream_failing' => tr(
    'خادم DNS في شبكتك لا يستجيب. إذا انقطع الإنترنت استخدم «وضع الأمان».',
    "Your network's DNS server isn't responding. If the internet stops working, use Safe Mode.",
  ),
  'no_blocking_rules' => tr(
    'لا توجد قوائم حظر للنطاقات بعد؛ يعمل الحظر على قوائمك وكلماتك فقط.',
    'No domain block lists yet; blocking works on your own lists and keywords only.',
  ),
  'model_unavailable' => tr(
    'نموذج الحماية الذكية غير متاح؛ القواعد تعمل.',
    'The AI protection model is unavailable; rules still work.',
  ),
  'database_error' => tr(
    'تعذّرت قراءة قاعدة البيانات المحلية.',
    "Couldn't read the local database.",
  ),
  final other when other != null && other.startsWith('accessibility') => tr(
    'لديك تطبيقات محمية لكن خدمة حماية التطبيقات غير مفعّلة.',
    'You have protected apps, but the app protection service is off.',
  ),
  _ => tr(
    'إحدى طبقات الحماية لا تعمل كما يجب. راجع شاشة الحالة.',
    "One of the protection layers isn't working as it should. Check the Status screen.",
  ),
};

/// Short Arabic label for one layer's state.
String layerStateLabel(LayerState s) => switch (s) {
  LayerState.active => tr('يعمل', 'Working'),
  LayerState.degraded => tr('جزئي', 'Partial'),
  LayerState.inactive => tr('متوقف', 'Stopped'),
  LayerState.off => tr('مطفأ', 'Off'),
  LayerState.notConfigured => tr('غير مُعد', 'Not set up'),
};

String modeLabel(ProtectionMode m) => switch (m) {
  ProtectionMode.normal => tr('عادي', 'Normal'),
  ProtectionMode.strict => tr('صارم', 'Strict'),
  ProtectionMode.custom => tr('مخصص', 'Custom'),
};
