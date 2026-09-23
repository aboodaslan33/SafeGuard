import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/app_logger.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_guard.dart';
import '../../search/presentation/search_protection_screen.dart' show SgNote;

/// AI Content Shield: on-device checking of content shown in supported
/// apps. Shows the real state: which parts actually run (text), which
/// don't (images, no model), and why.
///
/// Turning the shield or an app off loosens protection and needs the PIN;
/// turning it on follows Protection Lock like any other change.
class ContentShieldScreen extends StatefulWidget {
  const ContentShieldScreen({super.key});

  @override
  State<ContentShieldScreen> createState() => _ContentShieldScreenState();
}

class _ContentShieldScreenState extends State<ContentShieldScreen> {
  ShieldStatus? _status;
  bool _busy = false;
  late final AppLifecycleListener _lifecycle;

  ProtectionEngine get _engine => AppScope.of(context).protection.engine;

  @override
  void initState() {
    super.initState();
    // Back from Android's accessibility settings: re-read the state.
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    try {
      final s = await _engine.shieldStatus();
      if (mounted) setState(() => _status = s);
    } catch (e, st) {
      AppLogger.error('shield', e, st);
      if (mounted) setState(() => _status = ShieldStatus.unsupported);
    }
  }

  Future<void> _run(Future<ShieldStatus> Function() action) async {
    setState(() => _busy = true);
    try {
      final s = await action();
      if (mounted) setState(() => _status = s);
    } catch (e, st) {
      AppLogger.error('shield', e, st);
      if (mounted) {
        showSgSnack(
          context,
          tr('تعذّر حفظ التغيير', "Couldn't save the change"),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setEnabled(bool on) async {
    final ok = await ProtectionGuard.authorize(
      context,
      loosens: !on,
      reason: on
          ? tr('لتفعيل درع المحتوى الذكي', 'to turn on the AI Content Shield')
          : tr('لإيقاف درع المحتوى الذكي', 'to turn off the AI Content Shield'),
    );
    if (!ok || !mounted) return;
    await _run(() => _engine.setShieldEnabled(on));
    final s = _status;
    if (on && s != null && s.accessibility != AccessibilityStatus.enabled) {
      await _enableService();
    }
  }

  Future<void> _enableService() async {
    final accepted = await showSgBottomSheet<bool>(
      context,
      title: tr('تفعيل درع المحتوى الذكي', 'Turn on the AI Content Shield'),
      builder: (context) => const _ShieldDisclosure(),
    );
    if (accepted == null || !mounted) return;
    await _run(() => _engine.setShieldDisclosure(accepted: accepted));
    if (accepted) await _engine.openAccessibilitySettings();
  }

  Future<void> _setApp(ShieldApp app, bool on) async {
    final ok = await ProtectionGuard.authorize(
      context,
      loosens: !on,
      reason: on
          ? tr('لتفعيل فحص «${app.name}»', 'to start checking “${app.name}”')
          : tr('لإيقاف فحص «${app.name}»', 'to stop checking “${app.name}”'),
    );
    if (!ok || !mounted) return;
    await _run(() => _engine.setShieldAppEnabled(app.key, on));
  }

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    final s = _status;
    return SgPage(
      showBack: true,
      title: tr('درع المحتوى الذكي', 'AI Content Shield'),
      subtitle: tr(
        'فحص المحتوى الظاهر في تطبيقات مدعومة بالذكاء الاصطناعي على جهازك.',
        'On-device AI checks of content shown in supported apps.',
      ),
      children: [
        const SizedBox(height: SgSpace.x6),
        if (s == null)
          const SizedBox(height: 200, child: LoadingState())
        else ...[
          _StatusCard(
            status: s,
            onEnableService: _enableService,
            onOpenSettings: _engine.openAccessibilitySettings,
          ),
          const SizedBox(height: SgSpace.x3),
          SgGroupedCard(
            children: [
              SecuritySettingTile(
                icon: Icons.shield_moon_outlined,
                title: tr('درع المحتوى الذكي', 'AI Content Shield'),
                subtitle: s.enabled ? tr('مفعّل', 'On') : tr('متوقف', 'Off'),
                switchValue: s.enabled,
                onSwitchChanged: _busy || !_engine.isSupported
                    ? null
                    : _setEnabled,
              ),
            ],
          ),
          SectionHeader(
            title: tr('حالة نماذج الذكاء الاصطناعي', 'AI model status'),
          ),
          SgGroupedCard(
            children: [
              SecuritySettingTile(
                icon: Icons.notes_rounded,
                title: tr('نموذج النصوص', 'Text model'),
                subtitle: '${s.textModel} · ${tr('على الجهاز', 'on device')}',
                value: s.textModelAvailable
                    ? tr('متاح', 'Available')
                    : tr('غير متاح', 'Unavailable'),
                showChevron: false,
              ),
              SecuritySettingTile(
                icon: Icons.image_not_supported_outlined,
                title: tr('نموذج الصور', 'Image model'),
                subtitle: s.imageModelState.label,
                value: s.imageModelState.usable
                    ? tr('متاح', 'Available')
                    : tr('غير متاح', 'Unavailable'),
                showChevron: false,
              ),
            ],
          ),
          const SizedBox(height: SgSpace.x3),
          const _ModelNote(),
          SectionHeader(title: tr('التطبيقات المدعومة', 'Supported apps')),
          SgGroupedCard(
            children: [
              for (final app in s.apps)
                SecuritySettingTile(
                  icon: Icons.apps_rounded,
                  title: app.name,
                  subtitle: [
                    app.level.label,
                    if (!app.installed) tr('غير مثبّت', 'Not installed'),
                    if (!app.verifiedOnDevice)
                      tr(
                        'لم يُختبر على جهاز بعد',
                        'Not tested on a device yet',
                      ),
                  ].join(' · '),
                  switchValue: app.enabled,
                  onSwitchChanged: _busy || !s.enabled
                      ? null
                      : (v) => _setApp(app, v),
                ),
            ],
          ),
          const SizedBox(height: SgSpace.x3),
          _Limitations(apps: s.apps),
          SectionHeader(
            title: tr('الفئات ووضع الحماية', 'Categories and mode'),
          ),
          SgGroupedCard(
            children: [
              SecuritySettingTile(
                icon: Icons.tune_rounded,
                title: tr('وضع الحماية', 'Protection mode'),
                value: _modeLabel(protection.state.mode),
                onTap: () => context.push(Routes.aiProtection),
              ),
              SecuritySettingTile(
                icon: Icons.category_outlined,
                title: tr('الفئات', 'Categories'),
                subtitle: tr(
                  'نفس الفئات المفعّلة لفلترة الشبكة والبحث',
                  'The same categories as network and search filtering',
                ),
                onTap: () => context.push(Routes.categories),
              ),
            ],
          ),
          const SizedBox(height: SgSpace.x3),
          _Hint(
            tr(
              'في الوضع «صارم» يُحظر أيضًا المحتوى الإيحائي؛ في «عادي» يُحظر المحتوى الجنسي '
                  'الواضح فقط. نتيجة واحدة غير مؤكدة لا تحظر: يلزم تأكيدها بعيّنة ثانية.',
              'In “Strict” mode suggestive content is blocked too; in “Normal” only explicit sexual content is. A single uncertain result never blocks: it needs a second confirming sample.',
            ),
          ),
          SectionHeader(title: tr('الخصوصية', 'Privacy')),
          const _PrivacyCard(),
        ],
      ],
    );
  }

  static String _modeLabel(ProtectionMode m) => switch (m) {
    ProtectionMode.normal => tr('عادي', 'Normal'),
    ProtectionMode.strict => tr('صارم', 'Strict'),
    ProtectionMode.custom => tr('مخصص', 'Custom'),
  };
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.onEnableService,
    required this.onOpenSettings,
  });

  final ShieldStatus status;
  final VoidCallback onEnableService;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final pill = switch (s.state) {
      ShieldState.active => SgStatus.active,
      ShieldState.partial => SgStatus.paused,
      ShieldState.off => SgStatus.unavailable,
      ShieldState.unavailable => SgStatus.error,
    };
    final summary = switch (s.state) {
      ShieldState.off => tr(
        'الدرع متوقف. لا يُقرأ أي محتوى من التطبيقات.',
        'The shield is off. No app content is read.',
      ),
      ShieldState.active => tr(
        'يُفحص النص والصور في التطبيقات المدعومة المفعّلة.',
        'Text and images are checked in the supported apps you left on.',
      ),
      ShieldState.partial => tr(
        'يُفحص النص فقط في التطبيقات المدعومة المفعّلة. الصور والفيديو لا تُفحص.',
        "Only text is checked in the supported apps you left on. Photos and video aren't checked.",
      ),
      ShieldState.unavailable => tr(
        'الدرع مفعّل لكنه لا يفحص أي شيء الآن.',
        "The shield is on but isn't checking anything right now.",
      ),
    };
    final canEnable =
        s.enabled &&
        (s.accessibility == AccessibilityStatus.disabled ||
            s.accessibility == AccessibilityStatus.permissionDenied);
    return SgCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('حالة الدرع', 'Shield status'),
                  style: context.text.titleMedium,
                ),
              ),
              StatusIndicator(status: pill, label: s.state.label, dense: true),
            ],
          ),
          const SizedBox(height: SgSpace.x2),
          Text(summary, style: context.text.bodyMedium),
          const SizedBox(height: SgSpace.x3),
          _Capability(label: tr('فحص النصوص', 'Text checks'), on: s.textActive),
          _Capability(
            label: tr('فحص الصور والفيديو', 'Image and video checks'),
            on: s.imageActive,
          ),
          for (final issue in s.issues) ...[
            const SizedBox(height: SgSpace.x2),
            Text(
              '• ${issue.message}',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          ],
          if (canEnable) ...[
            const SizedBox(height: SgSpace.x4),
            SecondaryButton(
              label: tr('تفعيل الخدمة', 'Turn on service'),
              icon: Icons.accessibility_new_rounded,
              onPressed: onEnableService,
            ),
          ] else if (s.accessibility == AccessibilityStatus.enabled) ...[
            const SizedBox(height: SgSpace.x3),
            SgTextButton(
              label: tr(
                'إدارتها من إعدادات Android',
                'Manage in Android settings',
              ),
              onPressed: onOpenSettings,
            ),
          ],
        ],
      ),
    );
  }
}

class _Capability extends StatelessWidget {
  const _Capability({required this.label, required this.on});

  final String label;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: SgSpace.x1),
      child: Row(
        children: [
          Icon(
            on
                ? Icons.check_circle_rounded
                : Icons.remove_circle_outline_rounded,
            size: 18,
            color: on ? c.accent : c.textSecondary,
          ),
          const SizedBox(width: SgSpace.x2),
          Expanded(child: Text(label, style: context.text.bodyMedium)),
          Text(
            on ? tr('يعمل', 'Running') : tr('لا يعمل', 'Not running'),
            style: context.text.bodySmall?.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ModelNote extends StatelessWidget {
  const _ModelNote();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SgNote(
      icon: Icons.info_outline_rounded,
      color: c.info,
      background: c.infoMuted,
      text: tr(
        'لا يتضمّن هذا الإصدار نموذجًا لتصنيف الصور: لم يستوفِ أي نموذج متاح شروط الترخيص '
            'ومصدر بيانات التدريب والحجم والتحقق. لذلك لا تُفحص الصور والفيديو، ولا يدّعي '
            'SafeGuard ذلك. نموذج النصوص صغير ودقته محدودة.',
        "This version doesn't include an image classification model: no available model met the license, training-data provenance, size and verification bar. So photos and video aren't checked, and SafeGuard doesn't claim they are. The text model is small and of limited accuracy.",
      ),
    );
  }
}

class _Limitations extends StatelessWidget {
  const _Limitations({required this.apps});

  final List<ShieldApp> apps;

  @override
  Widget build(BuildContext context) {
    final all = <ShieldLimitation>{for (final a in apps) ...a.limitations};
    final c = context.colors;
    return SgNote(
      icon: Icons.warning_amber_rounded,
      color: c.warning,
      background: c.warningMuted,
      text: [
        tr(
          'لا يمكن ضمان فحص أو حظر كل محتوى في كل تطبيق.',
          "Checking or blocking every piece of content in every app can't be guaranteed.",
        ),
        for (final l in ShieldLimitation.values)
          if (all.contains(l)) '• ${l.message}',
      ].join('\n'),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard();

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
    return SgCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          point(
            Icons.phone_android_rounded,
            tr(
              'كل الفحص على جهازك. لا يُرفع أي نص أو صورة.',
              'All checks run on your device. No text or image is uploaded.',
            ),
          ),
          point(
            Icons.visibility_off_outlined,
            tr(
              'لا تُقرأ حقول الكتابة وكلمات المرور، وتُحذف الرموز والأرقام والروابط قبل الفحص.',
              'Input and password fields are never read; codes, numbers and links are dropped before checking.',
            ),
          ),
          point(
            Icons.no_photography_outlined,
            tr(
              'لا تُلتقط صور للشاشة ولا يُخزَّن أي محتوى.',
              'No screenshots are taken and no content is stored.',
            ),
          ),
          point(
            Icons.receipt_long_outlined,
            tr(
              'عند الحظر يُسجَّل فقط: الوقت، التطبيق، الفئة، الثقة التقريبية، نسخة النموذج.',
              'When something is blocked, only this is logged: time, app, category, rounded confidence, model version.',
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
    child: Text(
      text,
      style: context.text.bodySmall?.copyWith(
        color: context.colors.textSecondary,
      ),
    ),
  );
}

/// Prominent disclosure shown before sending the user to Android settings.
class _ShieldDisclosure extends StatelessWidget {
  const _ShieldDisclosure();

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
            'يستخدم درع المحتوى الذكي خدمة «تسهيل الاستخدام» (Accessibility) في Android '
                'لقراءة النص الظاهر على الشاشة في التطبيقات المدعومة فقط '
                '(Instagram وTikTok وYouTube وReddit وChrome وFirefox)، وفحصه على جهازك '
                'وفق إعدادات الحماية.',
            "The AI Content Shield uses Android's Accessibility service to read the text shown on screen in the supported apps only (Instagram, TikTok, YouTube, Reddit, Chrome, Firefox) and check it on your device against your protection settings.",
          ),
          style: context.text.bodyLarge,
        ),
        const SizedBox(height: SgSpace.x5),
        point(
          Icons.visibility_off_outlined,
          tr(
            'لا يقرأ ما تكتبه ولا كلمات المرور، ولا يعمل في أي تطبيق آخر.',
            "It doesn't read what you type or passwords, and doesn't run in any other app.",
          ),
        ),
        point(
          Icons.chat_bubble_outline_rounded,
          tr(
            'الرسائل الظاهرة في هذه التطبيقات تُفحص في الذاكرة مثل أي نص، ولا تُخزَّن.',
            "Messages shown in these apps are checked in memory like any text, and aren't stored.",
          ),
        ),
        point(
          Icons.phone_android_rounded,
          tr(
            'لا يغادر أي شيء جهازك، ولا تُلتقط صور للشاشة.',
            'Nothing leaves your device, and no screenshots are taken.',
          ),
        ),
        point(
          Icons.home_outlined,
          tr(
            'عند اكتشاف محتوى محظور يعيدك إلى الشاشة الرئيسية ويعرض شاشة الحظر.',
            'When blocked content is found, it sends you to the home screen and shows the block screen.',
          ),
        ),
        point(
          Icons.toggle_off_outlined,
          tr(
            'ستفعّلها بنفسك في إعدادات Android، ويمكنك إيقافها في أي وقت.',
            'You turn it on yourself in Android settings and can turn it off at any time.',
          ),
        ),
        const SizedBox(height: SgSpace.x4),
        PrimaryButton(
          label: tr('موافق، افتح الإعدادات', 'Agree, open settings'),
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: SgSpace.x2),
        SgTextButton(
          label: tr('لا أوافق', "I don't agree"),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }
}
