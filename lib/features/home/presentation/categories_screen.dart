import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_controller.dart';
import '../../protection/presentation/protection_ui.dart';

/// Categories with an honest note on how each one is detected: some have
/// large bundled domain lists, others rely on a few built-in rules, search
/// keywords and the on-device model.
class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key});

  static String coverage(ProtectionCategory c) => switch (c) {
    ProtectionCategory.sexual ||
    ProtectionCategory.gambling ||
    ProtectionCategory.drugs => tr(
      'قائمة نطاقات مضمّنة كبيرة + كلمات البحث + الذكاء الاصطناعي',
      'Large bundled domain list + search keywords + AI',
    ),
    ProtectionCategory.violence ||
    ProtectionCategory.gore ||
    ProtectionCategory.dangerous => tr(
      'قواعد قليلة مضمّنة + كلمات البحث + الذكاء الاصطناعي (لا توجد قائمة نطاقات كبيرة بعد)',
      'A few built-in rules + search keywords + AI (no large domain list yet)',
    ),
    ProtectionCategory.unsafeSearch => tr(
      'البحث الآمن المفروض عبر DNS في Google وBing وYouTube',
      'SafeSearch enforced through DNS on Google, Bing and YouTube',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) {
        final state = protection.state;
        final preset = state.mode.isPreset;
        final editable =
            protection.health != ProtectionHealth.paused && !preset;
        return SgPage(
          showBack: true,
          title: tr('الفئات', 'Categories'),
          subtitle: preset
              ? tr(
                  'يحددها وضع «${modeLabel(state.mode)}». اختر «مخصص» لتعديلها.',
                  'Set by the “${modeLabel(state.mode)}” mode. Choose Custom to edit them.',
                )
              : tr(
                  'تعطيل أي فئة يتطلب رمز PIN.',
                  'Turning off any category requires the PIN.',
                ),
          children: [
            for (final category in ProtectionCategory.values)
              Padding(
                padding: const EdgeInsets.only(bottom: SgSpace.x3),
                child: SgGroupedCard(
                  children: [
                    CategoryTile(
                      category: category,
                      active: state.isActive(category),
                      enabled: editable,
                      onChanged: (v) =>
                          ProtectionActions.setCategory(context, category, v),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        SgSpace.x4,
                        0,
                        SgSpace.x4,
                        SgSpace.x3,
                      ),
                      child: Text(
                        coverage(category),
                        style: context.text.bodySmall!.copyWith(
                          color: context.colors.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
