import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';

/// Answers one question: "am I protected, and from what?" — and lets the
/// user change exactly that. Everything else lives in Status or Settings.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) {
        final state = protection.state;
        final c = context.colors;
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
              state: state,
              onToggle: (v) => ProtectionActions.setEnabled(context, v),
            ),
            if (protection.engineStatus != EngineStatus.running) ...[
              const SizedBox(height: SgSpace.x3),
              _EngineNotice(onTap: () => context.go(Routes.status)),
            ],
            SectionHeader(
              title: 'الفئات المحجوبة',
              trailing: Text(
                state.enabled
                    ? '${state.activeCount} من ${ProtectionCategory.values.length}'
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
                    enabled: state.enabled,
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

/// Honest, low-key notice that the enforcement layer isn't active yet.
class _EngineNotice extends StatelessWidget {
  const _EngineNotice({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SgCard(
      onTap: onTap,
      color: c.infoMuted,
      borderColor: Colors.transparent,
      radius: SgRadius.mdAll,
      padding: const EdgeInsets.symmetric(
        horizontal: SgSpace.x4,
        vertical: SgSpace.x3,
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 20, color: c.info),
          const SizedBox(width: SgSpace.x3),
          Expanded(
            child: Text(
              'الفلترة الشبكية غير مفعّلة بعد في هذا الإصدار. '
              'تفضيلاتك محفوظة وستُطبَّق فور تفعيلها.',
              style: context.text.bodySmall!.copyWith(color: c.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
