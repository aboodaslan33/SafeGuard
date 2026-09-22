import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_controller.dart';
import '../../protection/presentation/protection_ui.dart';

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
        final categoriesEditable = health != ProtectionHealth.paused;
        return SgPage(
          header: Padding(
            padding: const EdgeInsets.only(bottom: SgSpace.x6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SafeGuardWordmark(),
                const SizedBox(height: SgSpace.x1),
                Text(
                  'حمايتك تبدأ من جهازك',
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
              onToggle: (v) => ProtectionActions.setEnabled(context, v),
              onRestart: () => ProtectionActions.restart(context),
            ),
            EngineWarnings(snapshot: protection.snapshot),
            SectionHeader(
              title: 'الفئات المحجوبة',
              trailing: Text(
                state.enabled
                    ? '${state.activeNetworkCount} من '
                          '${ProtectionCategory.networkFiltered.length}'
                    : 'متوقفة مؤقتًا',
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
                'تعطيل أي فئة أو إيقاف الحماية يتطلب رمز PIN.',
                style: context.text.bodySmall!.copyWith(color: c.textTertiary),
              ),
            ),
          ],
        );
      },
    );
  }
}
