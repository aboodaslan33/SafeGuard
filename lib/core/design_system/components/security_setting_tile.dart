import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';

/// Square icon well used at the start of every list row.
class SgIconWell extends StatelessWidget {
  const SgIconWell({
    super.key,
    required this.icon,
    this.foreground,
    this.background,
  });

  final IconData icon;
  final Color? foreground;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: SgMotion.medium,
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: background ?? c.surfaceSunken,
        borderRadius: SgRadius.mdAll,
      ),
      child: Icon(icon, size: 20, color: foreground ?? c.textSecondary),
    );
  }
}

/// One row inside an [SgGroupedCard]. Trailing is one of: a switch, a
/// value + chevron, or nothing.
class SecuritySettingTile extends StatelessWidget {
  const SecuritySettingTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.switchValue,
    this.onSwitchChanged,
    this.destructive = false,
    this.showChevron = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Short current value shown at the end (e.g. "داكن").
  final String? value;
  final VoidCallback? onTap;

  /// When non-null the row renders a switch instead of a chevron.
  final bool? switchValue;
  final ValueChanged<bool>? onSwitchChanged;
  final bool destructive;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSwitch = switchValue != null;
    final titleColor = destructive ? c.danger : c.textPrimary;

    Widget? trailing;
    if (isSwitch) {
      trailing = Switch(value: switchValue!, onChanged: onSwitchChanged);
    } else if (onTap != null && showChevron) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            Text(
              value!,
              style: context.text.bodyMedium!.copyWith(color: c.textTertiary),
            ),
          const SizedBox(width: SgSpace.x1),
          // chevron_left points "forward" in RTL.
          Icon(
            Directionality.of(context) == TextDirection.rtl
                ? Icons.chevron_left_rounded
                : Icons.chevron_right_rounded,
            color: c.textTertiary,
            size: 22,
          ),
        ],
      );
    }

    return MergeSemantics(
      child: InkWell(
        onTap: isSwitch
            ? (onSwitchChanged == null
                  ? null
                  : () => onSwitchChanged!(!switchValue!))
            : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SgSpace.x4,
            vertical: SgSpace.x3,
          ),
          child: Row(
            children: [
              SgIconWell(
                icon: icon,
                foreground: destructive ? c.danger : null,
                background: destructive ? c.dangerMuted : null,
              ),
              const SizedBox(width: SgSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: context.text.titleMedium!.copyWith(
                        color: titleColor,
                      ),
                    ),
                    if (subtitle != null)
                      Text(subtitle!, style: context.text.bodySmall),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: SgSpace.x2),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
