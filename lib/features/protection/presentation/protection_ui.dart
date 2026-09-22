import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../domain/protection.dart';

/// Presentation metadata for each category (kept out of the domain layer).
extension ProtectionCategoryUi on ProtectionCategory {
  String get title => switch (this) {
    ProtectionCategory.sexual => 'المحتوى الجنسي',
    ProtectionCategory.violence => 'المحتوى العنيف',
    ProtectionCategory.gore => 'المحتوى الدموي',
    ProtectionCategory.gambling => 'المقامرة',
    ProtectionCategory.drugs => 'المخدرات',
    ProtectionCategory.dangerous => 'المحتوى الخطِر',
    ProtectionCategory.unsafeSearch => 'فلترة البحث',
  };

  String get description => switch (this) {
    ProtectionCategory.sexual => 'المواقع الإباحية والمحتوى الصريح',
    ProtectionCategory.violence => 'مشاهد الإيذاء والعنف الجسدي',
    ProtectionCategory.gore => 'الصور والمقاطع الصادمة',
    ProtectionCategory.gambling => 'الكازينوهات ومواقع المراهنات',
    ProtectionCategory.drugs => 'الترويج للمخدرات وبيعها',
    ProtectionCategory.dangerous => 'إيذاء النفس والتحديات الخطرة',
    ProtectionCategory.unsafeSearch => 'فرض البحث الآمن في محركات البحث',
  };

  IconData get icon => switch (this) {
    ProtectionCategory.sexual => Icons.eighteen_up_rating_outlined,
    ProtectionCategory.violence => Icons.back_hand_outlined,
    ProtectionCategory.gore => Icons.water_drop_outlined,
    ProtectionCategory.gambling => Icons.casino_outlined,
    ProtectionCategory.drugs => Icons.medication_outlined,
    ProtectionCategory.dangerous => Icons.report_outlined,
    ProtectionCategory.unsafeSearch => Icons.manage_search_rounded,
  };
}

/// User-initiated protection changes. Loosening protection (turning it
/// off, or disabling a category) always requires the PIN; tightening never
/// does.
abstract final class ProtectionActions {
  static Future<void> setEnabled(BuildContext context, bool enabled) async {
    final protection = AppScope.of(context).protection;
    if (!enabled &&
        !await requirePin(context, reason: 'لإيقاف الحماية على هذا الجهاز')) {
      return;
    }
    final result = await protection.setEnabled(enabled);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  static Future<void> setCategory(
    BuildContext context,
    ProtectionCategory category,
    bool active,
  ) async {
    final protection = AppScope.of(context).protection;
    if (!active &&
        !await requirePin(
          context,
          reason: 'لإيقاف فلترة «${category.title}»',
        )) {
      return;
    }
    final result = await protection.setCategory(category, active);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }
}

/// Hero card on Home: current state in words, and the one action that
/// changes it. Turning protection off is deliberately the quieter button.
class ProtectionStatusCard extends StatelessWidget {
  const ProtectionStatusCard({
    super.key,
    required this.state,
    required this.onToggle,
  });

  final ProtectionState state;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final on = state.enabled;
    final tone = on ? c.accent : c.warning;

    return AnimatedContainer(
      duration: SgMotion.slow,
      curve: SgMotion.standard,
      decoration: BoxDecoration(
        borderRadius: SgRadius.xlAll,
        border: Border.all(color: tone.withValues(alpha: on ? 0.28 : 0.3)),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [(on ? c.accentMuted : c.warningMuted), c.surface],
          stops: const [0, 0.75],
        ),
        boxShadow: SgElevation.raised(dark: context.isDark),
      ),
      padding: const EdgeInsets.fromLTRB(
        SgSpace.x5,
        SgSpace.x5,
        SgSpace.x5,
        SgSpace.x5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusIndicator(
                      status: on ? SgStatus.active : SgStatus.paused,
                      label: on ? 'مفعّلة' : 'متوقفة',
                    ),
                    const SizedBox(height: SgSpace.x4),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        on ? 'الحماية مفعّلة' : 'الحماية متوقفة',
                        style: context.text.headlineSmall,
                      ),
                    ),
                    const SizedBox(height: SgSpace.x1),
                    Text(
                      on
                          ? _activeSummary(state.activeCount)
                          : 'لا يتم حجب أي محتوى حاليًا.',
                      style: context.text.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SgSpace.x4),
              ShieldMark(size: 52, color: tone, muted: !on),
            ],
          ),
          const SizedBox(height: SgSpace.x6),
          ProtectionToggle(enabled: on, onChanged: onToggle),
        ],
      ),
    );
  }

  static String _activeSummary(int n) => switch (n) {
    0 => 'لا توجد فئات مفعّلة.',
    1 => 'فئة واحدة محمية على هذا الجهاز.',
    2 => 'فئتان محميتان على هذا الجهاز.',
    _ when n <= 10 => '$n فئات محمية على هذا الجهاز.',
    _ => '$n فئة محمية على هذا الجهاز.',
  };
}

/// The master on/off action.
class ProtectionToggle extends StatelessWidget {
  const ProtectionToggle({
    super.key,
    required this.enabled,
    required this.onChanged,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: SgMotion.medium,
      child: SizedBox(
        key: ValueKey(enabled),
        width: double.infinity,
        child: enabled
            ? SecondaryButton(
                label: 'إيقاف الحماية',
                icon: Icons.pause_rounded,
                onPressed: () => onChanged(false),
              )
            : PrimaryButton(
                label: 'تفعيل الحماية',
                icon: Icons.shield_outlined,
                onPressed: () => onChanged(true),
              ),
      ),
    );
  }
}

/// One category row with its switch.
class CategoryTile extends StatelessWidget {
  const CategoryTile({
    super.key,
    required this.category,
    required this.active,
    required this.enabled,
    required this.onChanged,
  });

  final ProtectionCategory category;
  final bool active;

  /// False while global protection is off: the row is shown but inert.
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lit = active && enabled;
    return AnimatedOpacity(
      duration: SgMotion.medium,
      opacity: enabled ? 1 : 0.5,
      child: MergeSemantics(
        child: InkWell(
          onTap: enabled ? () => onChanged(!active) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SgSpace.x4,
              vertical: SgSpace.x3,
            ),
            child: Row(
              children: [
                SgIconWell(
                  icon: category.icon,
                  foreground: lit ? c.accent : c.textTertiary,
                  background: lit ? c.accentMuted : c.surfaceSunken,
                ),
                const SizedBox(width: SgSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(category.title, style: context.text.titleMedium),
                      Text(
                        category.description,
                        style: context.text.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: SgSpace.x2),
                Switch(value: active, onChanged: enabled ? onChanged : null),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
