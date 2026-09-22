import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
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
      title: 'تفعيل حماية التطبيقات',
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
      title: 'اختر تطبيقًا لحمايته',
      subtitle: 'لا تظهر هنا تطبيقات النظام والاتصال والإعدادات.',
      builder: (_) => _AppPicker(
        engine: _engine,
        exclude: {
          for (final a in _apps ?? const <ProtectedApp>[]) a.packageName,
        },
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await _engine.addProtectedApp(picked.packageName);
      if (mounted) showSgSnack(context, 'أصبح «${picked.label}» محميًا');
      await _refresh();
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
    }
  }

  Future<void> _remove(ProtectedApp app) async {
    if (!await requirePin(
      context,
      reason: 'لإزالة «${app.label}» من التطبيقات المحمية',
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
          title: 'حماية التطبيقات',
          subtitle: 'منع فتح تطبيقات تختارها على هذا الجهاز.',
          bottom: _engine.isSupported
              ? PrimaryButton(
                  label: 'إضافة تطبيق',
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
            const SectionHeader(title: 'التطبيقات المحمية'),
            if (_error != null)
              SizedBox(
                height: 280,
                child: ErrorState(
                  title: 'تعذّر تحميل القائمة',
                  message: _error,
                  onRetry: _refresh,
                ),
              )
            else if (apps == null)
              const SizedBox(height: 160, child: LoadingState())
            else if (apps.isEmpty)
              const SizedBox(
                height: 260,
                child: EmptyState(
                  icon: Icons.apps_rounded,
                  title: 'لا توجد تطبيقات محمية',
                  message: 'أضف تطبيقًا ليُمنع فتحه ما دامت الحماية نشطة.',
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
        'مفعّلة',
        'خدمة حماية التطبيقات تعمل. تعرف اسم التطبيق المفتوح فقط.',
      ),
      AccessibilityStatus.disabled => (
        SgStatus.paused,
        'غير مفعّلة',
        'لن تُحمى التطبيقات حتى تفعّل خدمة SafeGuard في إعدادات تسهيل الاستخدام.',
      ),
      AccessibilityStatus.permissionDenied => (
        SgStatus.paused,
        'مرفوضة',
        'اخترت عدم تفعيل الخدمة، لذلك لا تُحمى التطبيقات. يمكنك تغيير ذلك في أي وقت.',
      ),
      AccessibilityStatus.unavailable => (
        SgStatus.error,
        'غير متاحة',
        'هذا الجهاز أو الملف الشخصي لا يسمح بخدمات تسهيل الاستخدام من تطبيقات أخرى. '
            'قد يمنع Android تفعيلها للتطبيقات المثبتة من خارج المتجر (إعداد مقيّد).',
      ),
      AccessibilityStatus.unsupported => (
        SgStatus.unavailable,
        'غير متاحة',
        'حماية التطبيقات تعمل على أجهزة Android فقط.',
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
                  'خدمة حماية التطبيقات',
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
              label: 'تفعيل الخدمة',
              icon: Icons.accessibility_new_rounded,
              onPressed: onEnable,
            ),
          ] else if (status == AccessibilityStatus.enabled) ...[
            const SizedBox(height: SgSpace.x3),
            SgTextButton(
              label: 'إدارتها من إعدادات Android',
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
      text:
          'عند فتح تطبيق محمي يعيدك SafeGuard إلى الشاشة الرئيسية ويعرض شاشة «تطبيق محمي». '
          'لا يستطيع رؤية أو فلترة المحتوى داخل التطبيقات، ولا يمنع إزالة التطبيق أو '
          'إيقاف الخدمة من إعدادات Android. تطبيقات النظام والاتصال والإعدادات لا يمكن حمايتها.',
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
          'تستخدم حماية التطبيقات خدمة «تسهيل الاستخدام» (Accessibility) في Android '
          'لمعرفة اسم التطبيق الذي فُتح، حتى تمنع فتح التطبيقات التي اخترتها.',
          style: context.text.bodyLarge,
        ),
        const SizedBox(height: SgSpace.x5),
        point(
          Icons.visibility_off_outlined,
          'لا تقرأ محتوى الشاشة ولا ما تكتبه ولا رسائلك أو كلمات مرورك.',
        ),
        point(
          Icons.phone_android_rounded,
          'لا يغادر أي شيء جهازك، ولا تُستخدم لأي غرض آخر.',
        ),
        point(
          Icons.toggle_off_outlined,
          'ستفعّلها بنفسك في إعدادات Android، ويمكنك إيقافها في أي وقت.',
        ),
        const SizedBox(height: SgSpace.x4),
        PrimaryButton(
          label: 'موافق، افتح الإعدادات',
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: SgSpace.x2),
        SgTextButton(
          label: 'لا أوافق',
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
            tooltip: 'إزالة',
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
          decoration: const InputDecoration(
            hintText: 'بحث',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: SgSpace.x3),
        if (visible.isEmpty)
          const SizedBox(
            height: 120,
            child: EmptyState(
              icon: Icons.apps_rounded,
              title: 'لا توجد تطبيقات',
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
