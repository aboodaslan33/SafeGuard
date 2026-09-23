import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_controller.dart';
import '../../protection/presentation/protection_ui.dart';
import 'protection_dashboard.dart';

/// Answers one question: "am I protected right now, and from what?" — and
/// lets the user change exactly that. Details live in Status and Settings.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) {
        final state = protection.state;
        final health = protection.health;
        final c = context.colors;
        final preset = state.mode.isPreset;
        final categoriesEditable = health != ProtectionHealth.paused && !preset;
        return SgPage(
          header: Padding(
            padding: const EdgeInsets.only(bottom: SgSpace.x6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SafeGuardWordmark(),
                const SizedBox(height: SgSpace.x1),
                Text(
                  tr(
                    'حمايتك تبدأ من جهازك',
                    'Protection starts on your device',
                  ),
                  style: context.text.bodyMedium!.copyWith(
                    color: c.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          children: [
            ProtectionStatusCard(
              health: health,
              state: state,
              snapshot: protection.snapshot,
              report: protection.healthReport,
              pauseRemaining: protection.pauseRemaining,
              onToggle: (v) => ProtectionActions.setEnabled(context, v),
              onRestart: () => ProtectionActions.restart(context),
              onEndPause: () => protection.endPause(),
            ),
            InterruptionBanner(
              report: protection.healthReport,
              onRestart: () async {
                await ProtectionActions.restart(context);
                await protection.acknowledgeIncidents();
              },
              onDismiss: () => protection.acknowledgeIncidents(),
            ),
            EngineWarnings(snapshot: protection.snapshot),
            if (protection.engine.isSupported) ...[
              SectionHeader(title: tr('لوحة الحماية', 'Protection dashboard')),
              DashboardPanel(protection: protection),
            ],
            SectionHeader(title: tr('وضع الحماية', 'Protection mode')),
            ModeSelector(
              mode: state.mode,
              onChanged: state.enabled
                  ? (m) => ProtectionActions.setMode(context, m)
                  : null,
            ),
            SectionHeader(
              title: tr('الفئات المحجوبة', 'Blocked categories'),
              trailing: Text(
                !state.enabled
                    ? tr('متوقفة مؤقتًا', 'Paused')
                    : preset
                    ? tr('يحددها الوضع', 'Set by the mode')
                    : tr(
                        '${state.activeNetworkCount} من '
                            '${ProtectionCategory.networkFiltered.length}',
                        '${state.activeNetworkCount} of ${ProtectionCategory.networkFiltered.length}',
                      ),
                style: context.text.labelSmall,
              ),
            ),
            SgGroupedCard(
              children: [
                for (final category in ProtectionCategory.values)
                  CategoryTile(
                    key: ValueKey('category-${category.id}'),
                    category: category,
                    active: state.isActive(category),
                    enabled: categoriesEditable,
                    onChanged: (v) =>
                        ProtectionActions.setCategory(context, category, v),
                  ),
              ],
            ),
            const SizedBox(height: SgSpace.x3),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
              child: Text(
                preset
                    ? tr(
                        'في الوضعين «عادي» و«صارم» تُحجب كل الفئات. لاختيار الفئات '
                            'بنفسك اختر «مخصص» (يتطلب رمز PIN).',
                        'In Normal and Strict modes every category is blocked. To choose categories yourself, choose Custom (requires the PIN).',
                      )
                    : tr(
                        'تعطيل أي فئة أو إيقاف الحماية يتطلب رمز PIN.',
                        'Turning off any category or stopping protection requires the PIN.',
                      ),
                style: context.text.bodySmall!.copyWith(color: c.textTertiary),
              ),
            ),
          ],
        );
      },
    );
  }
}
