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

  Future<void> _startImageChecks() async {
    final agreed = await showSgBottomSheet<bool>(
      context,
      title: tr('تفعيل فحص الصور', 'Turn on image checks'),
      builder: (context) => const _CaptureDisclosure(),
    );
    if (agreed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final ok = await _engine.requestScreenCapture();
      if (!ok && mounted) {
        showSgSnack(
          context,
          tr(
            'لم يُسمح بالتقاط الشاشة، فالصور لا تُفحص.',
            "Screen capture wasn't allowed, so images aren't checked.",
          ),
        );
      }
    } catch (e, st) {
      AppLogger.error('shield', e, st);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  Future<void> _setAllApps(bool on) async {
    final ok = await ProtectionGuard.authorize(
      context,
      loosens: !on,
      reason: on
          ? tr('لفحص الصور في كل التطبيقات', 'to check images in every app')
          : tr(
              'لإيقاف فحص الصور في كل التطبيقات',
              'to stop checking images in every app',
            ),
    );
    if (!ok || !mounted) return;
    await _run(() => _engine.setShieldAllApps(on));
  }

  Future<void> _setMaxSensitivity(bool on) async {
    final ok = await ProtectionGuard.authorize(
      context,
      loosens: !on,
      reason: on
          ? tr('لتفعيل أقصى حساسية', 'to turn on maximum sensitivity')
          : tr('لإيقاف أقصى حساسية', 'to turn off maximum sensitivity'),
    );
    if (!ok || !mounted) return;
    await _run(() => _engine.setShieldMaxSensitivity(on));
  }

  Future<void> _stopImageChecks() async {
    final ok = await ProtectionGuard.authorize(
      context,
      loosens: true,
      reason: tr('لإيقاف فحص الصور', 'to turn off image checks'),
    );
    if (!ok || !mounted) return;
    await _engine.stopScreenCapture();
    await _refresh();
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
            title: tr('فحص الصور والفيديو', 'Image and video checks'),
          ),
          _ImageChecksCard(
            status: s,
            busy: _busy,
            onStart: _startImageChecks,
            onStop: _stopImageChecks,
          ),
          const SizedBox(height: SgSpace.x3),
          SgGroupedCard(
            children: [
              SecuritySettingTile(
                icon: Icons.apps_outage_rounded,
                title: tr(
                  'فحص الصور في كل التطبيقات',
                  'Check images in every app',
                ),
                subtitle: tr(
                  'وليس فقط التطبيقات المدعومة (عدا تطبيقات النظام والاتصال). النص يُقرأ فقط في التطبيقات المدعومة.',
                  'Not only the supported apps (system and phone apps excepted). Text is still read only in supported apps.',
                ),
                switchValue: s.allApps,
                onSwitchChanged: _busy || !s.enabled ? null : _setAllApps,
              ),
              SecuritySettingTile(
                icon: Icons.local_fire_department_outlined,
                title: tr('أقصى حساسية للصور', 'Maximum image sensitivity'),
                subtitle: tr(
                  'يحظر أيضًا الصور المثيرة والعري الجزئي من أول لقطة. يحظر أكثر، ومعه أخطاء أكثر (صور بحر ورياضة).',
                  'Also blocks revealing images and partial nudity from the first frame. Blocks more, with more mistakes (beach and sports photos).',
                ),
                switchValue: s.maxSensitivity,
                onSwitchChanged: _busy || !s.enabled
                    ? null
                    : _setMaxSensitivity,
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
                icon: Icons.image_search_rounded,
                title: tr('نموذج الصور', 'Image model'),
                subtitle: [
                  if (s.imageModel != null) s.imageModel!,
                  s.imageModelState.label,
                ].join(' · '),
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
              'لحظر الصور المثيرة والعري الجزئي (وليس الإباحي فقط) اختر الوضع «صارم». '
                  'في «عادي» يُحظر المحتوى الجنسي الواضح فقط. نتيجة واحدة غير مؤكدة لا '
                  'تحظر، إلا إذا كانت الثقة عالية جدًا.',
              'To also block revealing images and partial nudity (not only explicit content), choose “Strict” mode. “Normal” blocks clearly sexual content only. A single uncertain result never blocks unless confidence is very high.',
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
        'الدرع يعمل جزئيًا: جزء من الفحص متوقف (التفاصيل أدناه).',
        'The shield is partly running: some checks are off (details below).',
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
        'نموذج الصور: MobileNetV2 من مشروع nsfw_model (ترخيص MIT)، يعمل على الجهاز. '
            'يميّز: إباحي ورسوم إباحية (جنسي)، ومثير (إيحائي)، وآمن. دقته حسب مطوّريه '
            'حوالي 92% على بياناتهم؛ لم تُقَس على بيانات مستقلة. قد يخطئ: يحظر أحيانًا صور '
            'شاطئ أو رياضة، ويفوّت أحيانًا محتوى. بيانات تدريبه جُمعت من الإنترنت. '
            'نموذج النصوص صغير ودقته محدودة.',
        'Image model: MobileNetV2 from the nsfw_model project (MIT), running on your device. It tells apart porn and drawn porn (sexual), revealing images (suggestive) and safe images. Its authors report about 92% accuracy on their own data; it was not measured on independent data. It can be wrong: sometimes blocking beach or sports photos, sometimes missing content. Its training data was collected from the web. The text model is small and of limited accuracy.',
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
              'صور الشاشة (عند تشغيل فحص الصور) تُفحص في الذاكرة وتُحذف فورًا، ولا تُحفظ أو تُرسل أبدًا.',
              'Screen frames (while image checks are on) are checked in memory and discarded at once; they are never saved or sent.',
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
                '(Instagram وTikTok وYouTube وReddit وFacebook وChrome وFirefox)، وفحصه على جهازك '
                'وفق إعدادات الحماية.',
            "The AI Content Shield uses Android's Accessibility service to read the text shown on screen in the supported apps only (Instagram, TikTok, YouTube, Reddit, Facebook, Chrome, Firefox) and check it on your device against your protection settings.",
          ),
          style: context.text.bodyLarge,
        ),
        const SizedBox(height: SgSpace.x5),
        point(
          Icons.visibility_off_outlined,
          tr(
            'لا يقرأ كلمات المرور ولا ما تكتبه، إلا مربع البحث داخل هذه التطبيقات (لحظر البحث غير اللائق)، ولا يقرأ نصوص أي تطبيق آخر.',
            "It doesn't read passwords or what you type, except the search box inside these apps (to block unsuitable searches), and doesn't read text in any other app.",
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
            'لا يغادر أي شيء جهازك. هذه الخدمة لا تلتقط صورًا للشاشة (فحص الصور منفصل ويحتاج موافقتك).',
            'Nothing leaves your device. This service takes no screenshots (image checks are separate and need your consent).',
          ),
        ),
        point(
          Icons.home_outlined,
          tr(
            'عند اكتشاف محتوى محظور يغطّيه SafeGuard فورًا وينتقل إلى الريل أو المنشور التالي، دون أن يُخرجك من التطبيق. إن تكرر يبقى مغطّى حتى تختار «التالي» أو «رجوع». البحث المحظور داخل التطبيق يُمسح.',
            'When blocked content is found, SafeGuard covers it right away and swipes to the next reel or post, without taking you out of the app. If it keeps coming back, it stays covered until you choose Next or Back. A blocked search inside the app is cleared.',
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

/// Starts / stops screen capture for the image model.
class _ImageChecksCard extends StatelessWidget {
  const _ImageChecksCard({
    required this.status,
    required this.busy,
    required this.onStart,
    required this.onStop,
  });

  final ShieldStatus status;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final running = s.screenCaptureActive;
    final canStart = s.enabled && s.imageModelState.usable && !running && !busy;
    return SgCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('فحص الصور', 'Image checks'),
                  style: context.text.titleMedium,
                ),
              ),
              StatusIndicator(
                status: s.imageActive
                    ? SgStatus.active
                    : running
                    ? SgStatus.paused
                    : SgStatus.unavailable,
                label: s.imageActive
                    ? tr('يعمل', 'Running')
                    : running
                    ? tr('بانتظار الدرع', 'Waiting for the shield')
                    : tr('متوقف', 'Off'),
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: SgSpace.x2),
          Text(
            tr(
              'يفحص الصور والفيديو الظاهرة في التطبيقات المدعومة بنموذج على جهازك. يحتاج '
                  'موافقتك في نافذة «التقاط الشاشة» من Android، ويظهر مؤشر التسجيل طوال التشغيل. '
                  'بعد إعادة تشغيل الجهاز يجب التفعيل من جديد.',
              "Checks photos and video shown in supported apps with a model on your device. Needs your consent in Android's screen-capture dialog; Android shows its recording indicator the whole time. After a restart it has to be turned on again.",
            ),
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: SgSpace.x4),
          if (running)
            SgTextButton(
              label: tr('إيقاف فحص الصور', 'Turn off image checks'),
              onPressed: busy ? null : onStop,
            )
          else
            PrimaryButton(
              label: tr('تفعيل فحص الصور', 'Turn on image checks'),
              icon: Icons.image_search_rounded,
              onPressed: canStart ? onStart : null,
            ),
          if (!s.enabled) ...[
            const SizedBox(height: SgSpace.x2),
            Text(
              tr('فعّل الدرع أولًا.', 'Turn on the shield first.'),
              style: context.text.bodySmall?.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What image checks do, shown before Android's own consent dialog.
class _CaptureDisclosure extends StatelessWidget {
  const _CaptureDisclosure();

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
        point(
          Icons.screenshot_monitor_outlined,
          tr(
            'سيطلب Android موافقتك على «التقاط الشاشة». اختر مشاركة الشاشة كاملة.',
            'Android will ask you to allow screen capture. Choose to share the entire screen.',
          ),
        ),
        point(
          Icons.apps_rounded,
          tr(
            'تُفحص الشاشة فقط أثناء فتح تطبيق مدعوم فعّلته، وبحد أقصى حوالي مرة في الثانية.',
            'The screen is checked only while a supported app you left on is open, at most about once a second.',
          ),
        ),
        point(
          Icons.phone_android_rounded,
          tr(
            'كل صورة تُفحص في الذاكرة وتُحذف فورًا. لا شيء يُحفظ أو يُرسل.',
            'Each frame is checked in memory and discarded at once. Nothing is saved or sent.',
          ),
        ),
        point(
          Icons.battery_charging_full_rounded,
          tr(
            'يستهلك بطارية أكثر أثناء استخدام هذه التطبيقات.',
            'It uses more battery while you use these apps.',
          ),
        ),
        const SizedBox(height: SgSpace.x4),
        PrimaryButton(
          label: tr('متابعة', 'Continue'),
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
