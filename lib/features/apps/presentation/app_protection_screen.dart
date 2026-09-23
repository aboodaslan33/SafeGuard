import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../search/presentation/search_protection_screen.dart' show SgNote;

/// Protected apps: opening one sends the user home and shows SafeGuard's
/// "app protected" screen. Requires SafeGuard's accessibility service,
/// which the user turns on in Android settings after our disclosure.
class AppProtectionScreen extends StatefulWidget {
  const AppProtectionScreen({super.key});

  @override
  State<AppProtectionScreen> createState() => _AppProtectionScreenState();
}

class _AppProtectionScreenState extends State<AppProtectionScreen> {
  List<ProtectedApp>? _apps;
  String? _error;
  late final AppLifecycleListener _lifecycle;

  ProtectionEngine get _engine => AppScope.of(context).protection.engine;

  @override
  void initState() {
    super.initState();
    // Returning from Android's accessibility settings: re-read the state.
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
    final protection = AppScope.of(context).protection;
    await protection.refreshAppProtection();
    try {
      final apps = await _engine.protectedApps();
      if (mounted) {
        setState(() {
          _apps = apps;
          _error = null;
        });
      }
    } on AppFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    }
  }

  Future<void> _enableService() async {
    final accepted = await showSgBottomSheet<bool>(
      context,
      title: tr('تفعيل حماية التطبيقات', 'to turn on app protection'),
      builder: (context) => const _AccessibilityDisclosure(),
    );
    if (accepted == null || !mounted) return;
    await _engine.setAccessibilityDisclosure(accepted: accepted);
    if (accepted) await _engine.openAccessibilitySettings();
    await _refresh();
  }

  Future<void> _add() async {
    final picked = await showSgBottomSheet<InstalledApp>(
      context,
      title: tr('اختر تطبيقًا لحمايته', 'Choose an app to protect'),
      subtitle: tr(
        'لا تظهر هنا تطبيقات النظام والاتصال والإعدادات.',
        "System, phone and settings apps aren't listed.",
      ),
      builder: (_) => _AppPicker(
        engine: _engine,
        exclude: {
          for (final a in _apps ?? const <ProtectedApp>[]) a.packageName,
        },
      ),
    );
    if (picked == null || !mounted) return;
    if (await _coveredByShield(picked.packageName)) {
      if (!mounted) return;
      final blockWholeApp = await showSgConfirmDialog(
        context,
        title: tr('هذا يمنع فتح التطبيق كله', 'This blocks the whole app'),
        message: tr(
          'حماية التطبيقات تمنع فتح «${picked.label}» كليًا، مهما كان المحتوى. '
              'لحجب المحتوى الجنسي والعاري فقط داخله مع بقاء التطبيق يعمل، '
              'استخدم «درع المحتوى» ولا تضفه هنا.',
          'App protection stops “${picked.label}” from opening at all, whatever '
              'it shows. To hide only sexual or nude content inside it and keep '
              "using the app, use the Content Shield and don't add it here.",
        ),
        confirmLabel: tr('منع التطبيق كله', 'Block the whole app'),
        cancelLabel: tr('إلغاء', 'Cancel'),
      );
      if (!blockWholeApp || !mounted) return;
    }
    try {
      await _engine.addProtectedApp(picked.packageName);
      if (mounted) {
        showSgSnack(
          context,
          tr(
            'أصبح «${picked.label}» محميًا',
            '“${picked.label}” is now protected',
          ),
        );
      }
      await _refresh();
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
    }
  }

  /// Whether the AI Content Shield can filter this app's content instead.
  Future<bool> _coveredByShield(String packageName) async {
    try {
      final status = await _engine.shieldStatus();
      return status.apps.any((a) => a.packages.contains(packageName));
    } on AppFailure {
      return false;
    }
  }

  Future<void> _remove(ProtectedApp app) async {
    if (!await requirePin(
      context,
      reason: tr(
        'لإزالة «${app.label}» من التطبيقات المحمية',
        'to remove “${app.label}” from protected apps',
      ),
    )) {
      return;
    }
    try {
      await _engine.removeProtectedApp(app.packageName);
      await _refresh();
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) {
        final status = protection.accessibility;
        final apps = _apps;
        return SgPage(
          showBack: true,
          title: tr('حماية التطبيقات', 'App protection'),
          subtitle: tr(
            'منع فتح تطبيقات تختارها على هذا الجهاز.',
            'Stop apps you choose from opening on this device.',
          ),
          bottom: _engine.isSupported
              ? PrimaryButton(
                  label: tr('إضافة تطبيق', 'Add app'),
                  icon: Icons.add_rounded,
                  onPressed: _add,
                )
              : null,
          children: [
            const SizedBox(height: SgSpace.x6),
            _ServiceCard(
              status: status,
              onEnable: _enableService,
              onOpenSettings: _engine.openAccessibilitySettings,
            ),
            const SizedBox(height: SgSpace.x3),
            const _Capabilities(),
            SectionHeader(title: tr('التطبيقات المحمية', 'Protected apps')),
            if (_error != null)
              SizedBox(
                height: 280,
                child: ErrorState(
                  title: tr('تعذّر تحميل القائمة', "Couldn't load the list"),
                  message: _error,
                  onRetry: _refresh,
                ),
              )
            else if (apps == null)
              const SizedBox(height: 160, child: LoadingState())
            else if (apps.isEmpty)
              SizedBox(
                height: 260,
                child: EmptyState(
                  icon: Icons.apps_rounded,
                  title: tr('لا توجد تطبيقات محمية', 'No protected apps'),
                  message: tr(
                    'أضف تطبيقًا ليُمنع فتحه ما دامت الحماية نشطة.',
                    'Add an app to stop it from opening while protection is active.',
                  ),
                ),
              )
            else
              SgGroupedCard(
                children: [
                  for (final app in apps)
                    _AppRow(app: app, onRemove: () => _remove(app)),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.status,
    required this.onEnable,
    required this.onOpenSettings,
  });

  final AccessibilityStatus status;
  final VoidCallback onEnable;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final (SgStatus pill, String label, String body) = switch (status) {
      AccessibilityStatus.enabled => (
        SgStatus.active,
        tr('مفعّلة', 'On'),
        tr(
          'خدمة حماية التطبيقات تعمل. تعرف اسم التطبيق المفتوح فقط.',
          'The app protection service is running. It only knows the name of the app that opened.',
        ),
      ),
      AccessibilityStatus.disabled => (
        SgStatus.paused,
        tr('غير مفعّلة', 'Off'),
        tr(
          'لن تُحمى التطبيقات حتى تفعّل خدمة SafeGuard في إعدادات تسهيل الاستخدام.',
          "Apps won't be protected until you turn on the SafeGuard service in Accessibility settings.",
        ),
      ),
      AccessibilityStatus.permissionDenied => (
        SgStatus.paused,
        tr('مرفوضة', 'Declined'),
        tr(
          'اخترت عدم تفعيل الخدمة، لذلك لا تُحمى التطبيقات. يمكنك تغيير ذلك في أي وقت.',
          "You chose not to turn on the service, so apps aren't protected. You can change this at any time.",
        ),
      ),
      AccessibilityStatus.unavailable => (
        SgStatus.error,
        tr('غير متاحة', 'Unavailable'),
        tr(
          'هذا الجهاز أو الملف الشخصي لا يسمح بخدمات تسهيل الاستخدام من تطبيقات أخرى. '
              'قد يمنع Android تفعيلها للتطبيقات المثبتة من خارج المتجر (إعداد مقيّد).',
          "This device or profile doesn't allow accessibility services from other apps. Android may block them for apps installed outside the store (restricted setting).",
        ),
      ),
      AccessibilityStatus.unsupported => (
        SgStatus.unavailable,
        tr('غير متاحة', 'Unavailable'),
        tr(
          'حماية التطبيقات تعمل على أجهزة Android فقط.',
          'App protection works on Android devices only.',
        ),
      ),
    };
    final canEnable =
        status == AccessibilityStatus.disabled ||
        status == AccessibilityStatus.permissionDenied;
    return SgCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('خدمة حماية التطبيقات', 'App protection service'),
                  style: context.text.titleMedium,
                ),
              ),
              StatusIndicator(status: pill, label: label, dense: true),
            ],
          ),
          const SizedBox(height: SgSpace.x2),
          Text(body, style: context.text.bodyMedium),
          if (canEnable) ...[
            const SizedBox(height: SgSpace.x4),
            SecondaryButton(
              label: tr('تفعيل الخدمة', 'Turn on service'),
              icon: Icons.accessibility_new_rounded,
              onPressed: onEnable,
            ),
          ] else if (status == AccessibilityStatus.enabled) ...[
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

/// Plain statement of what App Protection does and does not do.
class _Capabilities extends StatelessWidget {
  const _Capabilities();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SgNote(
      icon: Icons.info_outline_rounded,
      color: c.info,
      background: c.infoMuted,
      text: tr(
        'عند فتح تطبيق محمي يعيدك SafeGuard إلى الشاشة الرئيسية ويعرض شاشة «تطبيق محمي». '
            'لا يستطيع رؤية أو فلترة المحتوى داخل التطبيقات، ولا يمنع إزالة التطبيق أو '
            'إيقاف الخدمة من إعدادات Android. تطبيقات النظام والاتصال والإعدادات لا يمكن حمايتها.',
        "When a protected app opens, SafeGuard returns you to the home screen and shows a “Protected app” screen. It can't see or filter content inside apps, and it doesn't prevent uninstalling the app or turning off the service in Android settings. System, phone and settings apps can't be protected.",
      ),
    );
  }
}

class _AccessibilityDisclosure extends StatelessWidget {
  const _AccessibilityDisclosure();

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
            'تستخدم حماية التطبيقات خدمة «تسهيل الاستخدام» (Accessibility) في Android '
                'لمعرفة اسم التطبيق الذي فُتح، حتى تمنع فتح التطبيقات التي اخترتها.',
            "App protection uses Android's Accessibility service to learn the name of the app that opened, so it can stop the apps you chose from opening.",
          ),
          style: context.text.bodyLarge,
        ),
        const SizedBox(height: SgSpace.x5),
        point(
          Icons.visibility_off_outlined,
          tr(
            'لا تقرأ محتوى الشاشة ولا ما تكتبه ولا رسائلك أو كلمات مرورك.',
            "It doesn't read screen content, what you type, your messages or passwords.",
          ),
        ),
        point(
          Icons.phone_android_rounded,
          tr(
            'لا يغادر أي شيء جهازك، ولا تُستخدم لأي غرض آخر.',
            "Nothing leaves your device, and it isn't used for anything else.",
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

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.onRemove});

  final ProtectedApp app;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: SgSpace.x4,
        end: SgSpace.x1,
        top: SgSpace.x2,
        bottom: SgSpace.x2,
      ),
      child: Row(
        children: [
          const SgIconWell(icon: Icons.apps_rounded),
          const SizedBox(width: SgSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.titleMedium,
                ),
                Text(
                  app.packageName,
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: tr('إزالة', 'Remove'),
            icon: Icon(
              Icons.remove_circle_outline_rounded,
              color: c.textTertiary,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.engine, required this.exclude});

  final ProtectionEngine engine;
  final Set<String> exclude;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  List<InstalledApp>? _apps;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    widget.engine.launchableApps().then(
      (apps) {
        if (mounted) setState(() => _apps = apps);
      },
      onError: (Object _) {
        if (mounted) setState(() => _apps = const []);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final apps = _apps;
    if (apps == null) return const SizedBox(height: 160, child: LoadingState());
    final f = _filter.toLowerCase();
    final visible = apps
        .where((a) => !widget.exclude.contains(a.packageName))
        .where(
          (a) =>
              f.isEmpty ||
              a.label.toLowerCase().contains(f) ||
              a.packageName.contains(f),
        )
        .take(200)
        .toList();
    return Column(
      children: [
        TextField(
          onChanged: (v) => setState(() => _filter = v.trim()),
          decoration: InputDecoration(
            hintText: tr('بحث', 'Search'),
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: SgSpace.x3),
        if (visible.isEmpty)
          SizedBox(
            height: 120,
            child: EmptyState(
              icon: Icons.apps_rounded,
              title: tr('لا توجد تطبيقات', 'No apps'),
            ),
          )
        else
          for (final app in visible)
            SgChoiceRow(
              label: app.label,
              icon: Icons.apps_rounded,
              selected: false,
              onTap: () => Navigator.of(context).pop(app),
            ),
      ],
    );
  }
}
