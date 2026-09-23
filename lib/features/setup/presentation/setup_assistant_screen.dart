import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../domain/setup_checks.dart';
import 'setup_ui.dart';

/// Permission & setup assistant: what's in place, what's missing, why each
/// item matters, what depends on it and how to fix it. Re-checks when the
/// user comes back from Android settings, so nothing fails silently.
class SetupAssistantScreen extends StatefulWidget {
  const SetupAssistantScreen({super.key});

  @override
  State<SetupAssistantScreen> createState() => _SetupAssistantScreenState();
}

class _SetupAssistantScreenState extends State<SetupAssistantScreen> {
  List<SetupCheck>? _checks;
  bool _failed = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _load);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final facts = await loadSetupFacts(AppScope.of(context).protection);
      if (!mounted) return;
      setState(() {
        _checks = evaluateSetup(facts);
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    final checks = _checks;
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) => SgPage(
        showBack: true,
        title: tr('مساعد الإعداد', 'Setup assistant'),
        subtitle: tr(
          'ما يلزم لتعمل الحماية، ولماذا.',
          'What protection needs to work, and why.',
        ),
        children: [
          OverallStatusCard(overall: protection.healthReport.overall),
          const SizedBox(height: SgSpace.x4),
          if (_failed)
            ErrorState(
              title: tr('تعذّر فحص الإعداد', "Couldn't check the setup"),
              retryLabel: tr('إعادة المحاولة', 'Try again'),
              onRetry: _load,
            )
          else if (checks == null)
            const LoadingState()
          else ...[
            for (final check in checks)
              SetupCheckCard(
                key: ValueKey('check-${check.id.name}'),
                check: check,
                onAction: check.action == null
                    ? null
                    : () async {
                        await runCheckAction(context, check.action!);
                        await _load();
                      },
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
              child: Text(
                tr(
                  'لا يطلب SafeGuard أذونات الجذر (root) ولا أي صلاحيات تتجاوز أمان Android. '
                      'بعض القيود (مثل DNS المشفّر داخل التطبيقات) لا يمكن لأي تطبيق تجاوزها.',
                  "SafeGuard doesn't ask for root or anything that bypasses Android security. "
                      "Some limits (like encrypted DNS inside apps) can't be overcome by any app.",
                ),
                style: context.text.bodySmall!.copyWith(
                  color: context.colors.textTertiary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
