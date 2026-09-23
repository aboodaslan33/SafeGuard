import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';
import '../domain/setup_checks.dart';
import 'setup_ui.dart';

/// Final wizard verdict. ACTIVE only when native health reports every
/// enabled layer working — never assumed from the user's choices.
enum WizardResult { active, partial, failed }

WizardResult wizardResultFor(OverallHealth overall) => switch (overall) {
  OverallHealth.protected => WizardResult.active,
  OverallHealth.partiallyProtected => WizardResult.partial,
  _ => WizardResult.failed,
};

/// "Enable SafeGuard Protection": mode → categories → apps → search → AI →
/// PIN → permissions → verification.
///
/// On first run it follows PIN creation (the PIN step then shows it as
/// done). Opened later from Settings it asks for the PIN first, because
/// several steps can loosen protection.
class SetupWizardScreen extends StatefulWidget {
  const SetupWizardScreen({super.key});

  static const stepCount = 8;

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  int _step = 0;
  bool _authorized = false;
  bool _busy = false;
  List<SetupCheck>? _checks;
  WizardResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _authorize());
  }

  Future<void> _authorize() async {
    final deps = AppScope.of(context);
    if (deps.settings.setupPending) {
      setState(() => _authorized = true);
      return;
    }
    final ok = await requirePin(
      context,
      reason: tr('لإعداد الحماية', 'to set up protection'),
    );
    if (!mounted) return;
    if (ok) {
      setState(() => _authorized = true);
    } else {
      _leave();
    }
  }

  void _leave() {
    AppScope.of(context).settings.setupPending = false;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.home);
    }
  }

  Future<void> _next() async {
    if (_step == SetupWizardScreen.stepCount - 1) return _leave();
    setState(() => _step++);
    if (_step == 6) await _loadChecks();
    if (_step == 7) await _verify();
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  Future<void> _loadChecks() async {
    try {
      final facts = await loadSetupFacts(AppScope.of(context).protection);
      if (mounted) setState(() => _checks = evaluateSetup(facts));
    } catch (_) {
      if (mounted) setState(() => _checks = const []);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final protection = AppScope.of(context).protection;
    try {
      await protection.refreshStatus();
      await protection.refreshHealth();
      if (!mounted) return;
      setState(
        () => _result = wizardResultFor(protection.healthReport.overall),
      );
    } catch (_) {
      if (mounted) setState(() => _result = WizardResult.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<Result<void>> Function() call) async {
    final result = await call();
    if (result case Err(:final failure) when mounted) {
      showSgSnack(context, failure.message);
    }
  }

  static String _stepTitle(int i) => switch (i) {
    0 => tr('وضع الحماية', 'Protection mode'),
    1 => tr('الفئات', 'Categories'),
    2 => tr('التطبيقات المحمية', 'Protected apps'),
    3 => tr('حماية البحث', 'Search protection'),
    4 => tr('الحماية الذكية', 'AI protection'),
    5 => tr('رمز PIN', 'PIN'),
    6 => tr('الأذونات', 'Permissions'),
    _ => tr('التحقق من الحماية', 'Verify protection'),
  };

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    if (!_authorized) {
      return const Scaffold(body: LoadingState());
    }
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) => SgPage(
        title: tr('تفعيل حماية SafeGuard', 'Enable SafeGuard Protection'),
        subtitle: tr(
          'الخطوة ${_step + 1} من ${SetupWizardScreen.stepCount}: ${_stepTitle(_step)}',
          'Step ${_step + 1} of ${SetupWizardScreen.stepCount}: ${_stepTitle(_step)}',
        ),
        bottom: Row(
          children: [
            if (_step > 0 && _step < 7) ...[
              Expanded(
                child: SecondaryButton(
                  label: tr('السابق', 'Back'),
                  onPressed: _back,
                ),
              ),
              const SizedBox(width: SgSpace.x3),
            ],
            Expanded(
              child: PrimaryButton(
                label: _step == 7
                    ? tr('إنهاء', 'Finish')
                    : _step == 6
                    ? tr('تحقق', 'Verify')
                    : tr('التالي', 'Next'),
                loading: _busy,
                onPressed: _busy ? null : _next,
              ),
            ),
          ],
        ),
        children: [
          LinearProgressIndicator(
            value: (_step + 1) / SetupWizardScreen.stepCount,
            minHeight: 4,
            borderRadius: SgRadius.pillAll,
          ),
          const SizedBox(height: SgSpace.x5),
          ..._stepBody(context),
          if (_step < 7)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: SgTextButton(
                label: tr('إكمال لاحقًا', 'Finish later'),
                onPressed: _leave,
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _stepBody(BuildContext context) {
    final deps = AppScope.of(context);
    final protection = deps.protection;
    final state = protection.state;
    final c = context.colors;
    Text note(String s) =>
        Text(s, style: context.text.bodySmall!.copyWith(color: c.textTertiary));

    switch (_step) {
      case 0:
        return [
          SgGroupedCard(
            children: [
              for (final m in ProtectionMode.values)
                SgChoiceRow(
                  label: modeLabel(m),
                  description: switch (m) {
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
                  },
                  selected: state.mode == m,
                  onTap: () => _run(() => protection.setMode(m)),
                ),
            ],
          ),
          const SizedBox(height: SgSpace.x3),
        ];
      case 1:
        return [
          if (state.mode.isPreset) ...[
            note(
              tr(
                'في وضع «${modeLabel(state.mode)}» تُحجب كل الفئات. للاختيار بنفسك ارجع واختر «مخصص».',
                'In “${modeLabel(state.mode)}” mode every category is blocked. To choose yourself, go back and pick Custom.',
              ),
            ),
            const SizedBox(height: SgSpace.x3),
          ],
          SgGroupedCard(
            children: [
              for (final category in ProtectionCategory.values)
                CategoryTile(
                  category: category,
                  active: state.isActive(category),
                  enabled: !state.mode.isPreset,
                  onChanged: (v) =>
                      _run(() => protection.setCategory(category, v)),
                ),
            ],
          ),
          const SizedBox(height: SgSpace.x3),
        ];
      case 2:
        return [
          SgCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(
                    'اختياري: امنع فتح تطبيقات معينة. تحتاج هذه الميزة خدمة «تسهيل الاستخدام»، وتعرف اسم التطبيق المفتوح فقط.',
                    'Optional: stop specific apps from opening. This needs the Accessibility service, which only learns the name of the app that opened.',
                  ),
                  style: context.text.bodyMedium,
                ),
                const SizedBox(height: SgSpace.x3),
                Text(
                  tr(
                    'التطبيقات المحمية: ${protection.protectedAppCount}',
                    'Protected apps: ${protection.protectedAppCount}',
                  ),
                  style: context.text.labelMedium,
                ),
                const SizedBox(height: SgSpace.x3),
                SecondaryButton(
                  label: tr('اختيار التطبيقات', 'Choose apps'),
                  onPressed: protection.engine.isSupported
                      ? () async {
                          await context.push(Routes.appProtection);
                          await protection.refreshAppProtection();
                        }
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: SgSpace.x3),
        ];
      case 3:
        return [
          SgGroupedCard(
            children: [
              SecuritySettingTile(
                icon: Icons.manage_search_rounded,
                title: tr('حماية البحث', 'Search protection'),
                subtitle: tr(
                  'البحث الآمن في Google وBing والوضع المقيّد في YouTube',
                  'SafeSearch on Google and Bing, Restricted Mode on YouTube',
                ),
                switchValue: protection.searchProtectionEnabled,
                onSwitchChanged: state.mode.isPreset
                    ? null
                    : (v) => _run(
                        () => protection.setSearchSettings(
                          protection.searchSettings.copyWith(enabled: v),
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: SgSpace.x3),
          note(
            tr(
              'يعمل عندما يستخدم المتصفح DNS النظام. «DNS الآمن» في Chrome قد يتجاوزه.',
              "Works when the browser uses the system DNS. Chrome's Secure DNS may bypass it.",
            ),
          ),
          const SizedBox(height: SgSpace.x3),
        ];
      case 4:
        return [
          SgGroupedCard(
            children: [
              SecuritySettingTile(
                icon: Icons.auto_awesome_outlined,
                title: tr('الحماية الذكية', 'AI protection'),
                subtitle: tr(
                  'تصنيف نص البحث على الجهاز، دون رفع أي شيء',
                  'On-device classification of search text; nothing is uploaded',
                ),
                switchValue: protection.aiSettings.enabled,
                onSwitchChanged: state.mode.isPreset
                    ? null
                    : (v) => _run(
                        () => protection.setAiSettings(
                          protection.aiSettings.copyWith(enabled: v),
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: SgSpace.x3),
          note(
            tr(
              'النموذج صغير ومحدود الدقة. إذا تعذّر عمله تستمر الحماية بالقواعد.',
              'The model is small with limited accuracy. If it can\'t run, rule-based protection continues.',
            ),
          ),
          const SizedBox(height: SgSpace.x3),
        ];
      case 5:
        return [
          SgCard(
            child: Row(
              children: [
                StatusIndicator(
                  status: deps.security.pinSet
                      ? SgStatus.active
                      : SgStatus.error,
                  label: deps.security.pinSet
                      ? tr('تم الإنشاء', 'Created')
                      : tr('غير موجود', 'Missing'),
                ),
                const SizedBox(width: SgSpace.x3),
                Expanded(
                  child: Text(
                    tr(
                      'رمز PIN من ${deps.security.pinLength} أرقام يحمي إيقاف الحماية وتخفيفها.',
                      'A ${deps.security.pinLength}-digit PIN protects against turning protection off or loosening it.',
                    ),
                    style: context.text.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: SgSpace.x3),
          SgTextButton(
            label: tr('تغيير رمز PIN', 'Change PIN'),
            onPressed: () => context.push(Routes.changePin),
          ),
          const SizedBox(height: SgSpace.x3),
        ];
      case 6:
        final checks = _checks;
        final relevant = checks
            ?.where((c) => c.status != CheckStatus.notNeeded)
            .toList();
        return [
          if (relevant == null)
            const LoadingState()
          else
            for (final check in relevant)
              SetupCheckCard(
                key: ValueKey('wizard-check-${check.id.name}'),
                check: check,
                onAction: check.action == null
                    ? null
                    : () async {
                        await runCheckAction(context, check.action!);
                        await _loadChecks();
                      },
              ),
        ];
      default:
        final result = _result;
        if (_busy || result == null) return const [LoadingState()];
        final (label, tone) = switch (result) {
          WizardResult.active => (tr('نشطة', 'ACTIVE'), c.accent),
          WizardResult.partial => (tr('جزئية', 'PARTIAL'), c.warning),
          WizardResult.failed => (tr('فشلت', 'FAILED'), c.danger),
        };
        return [
          SgCard(
            borderColor: tone.withValues(alpha: 0.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('حماية SafeGuard:', 'SafeGuard Protection:'),
                  style: context.text.titleMedium,
                ),
                const SizedBox(height: SgSpace.x2),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    label,
                    style: context.text.headlineSmall!.copyWith(color: tone),
                  ),
                ),
                const SizedBox(height: SgSpace.x2),
                Text(switch (result) {
                  WizardResult.active => tr(
                    'كل الطبقات المفعّلة تعمل الآن على هذا الجهاز.',
                    'Every enabled layer is working on this device now.',
                  ),
                  WizardResult.partial => partialReason(
                    protection.healthReport,
                  ),
                  WizardResult.failed => tr(
                    'فلترة الشبكة لا تعمل. افتح «مساعد الإعداد» لمعرفة السبب.',
                    "Network filtering isn't running. Open the Setup assistant to see why.",
                  ),
                }, style: context.text.bodyMedium),
              ],
            ),
          ),
          const SizedBox(height: SgSpace.x3),
          if (result != WizardResult.active)
            SecondaryButton(
              label: tr('فتح مساعد الإعداد', 'Open setup assistant'),
              onPressed: () => context.push(Routes.setupAssistant),
            ),
          SgTextButton(
            label: tr('إعادة التحقق', 'Check again'),
            onPressed: _verify,
          ),
        ];
    }
  }
}
