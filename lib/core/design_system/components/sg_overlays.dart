import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';
import 'sg_buttons.dart';

/// Confirmation dialog. Used only for irreversible actions; everything
/// else uses a bottom sheet or happens inline.
Future<bool> showSgConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'إلغاء',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: SgSpace.x6,
          vertical: SgSpace.x8,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              SgSpace.x6,
              SgSpace.x6,
              SgSpace.x6,
              SgSpace.x5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: context.text.titleLarge),
                const SizedBox(height: SgSpace.x2),
                Text(message, style: context.text.bodyMedium),
                const SizedBox(height: SgSpace.x6),
                destructive
                    ? SecondaryButton(
                        label: confirmLabel,
                        destructive: true,
                        onPressed: () => Navigator.of(context).pop(true),
                      )
                    : PrimaryButton(
                        label: confirmLabel,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                const SizedBox(height: SgSpace.x2),
                SgTextButton(
                  label: cancelLabel,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return result ?? false;
}

/// Modal bottom sheet with a grab handle and title.
Future<T?> showSgBottomSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: SgSpace.maxContentWidth),
    builder: (context) {
      final c = context.colors;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          SgSpace.x5,
          SgSpace.x3,
          SgSpace.x5,
          SgSpace.x6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.borderStrong,
                  borderRadius: SgRadius.pillAll,
                ),
              ),
            ),
            const SizedBox(height: SgSpace.x5),
            Text(title, style: context.text.titleLarge),
            if (subtitle != null) ...[
              const SizedBox(height: SgSpace.x1),
              Text(subtitle, style: context.text.bodyMedium),
            ],
            const SizedBox(height: SgSpace.x4),
            builder(context),
          ],
        ),
      );
    },
  );
}

/// Single-choice option row (bottom sheets, mode pickers).
class SgChoiceRow extends StatelessWidget {
  const SgChoiceRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.description,
  });

  final String label;
  final bool selected;

  /// Null disables the row.
  final VoidCallback? onTap;
  final IconData? icon;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final description = this.description;
    return Semantics(
      selected: selected,
      button: true,
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: SgRadius.mdAll,
        child: Opacity(
          opacity: onTap == null && !selected ? 0.5 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SgSpace.x3,
              vertical: SgSpace.x3,
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: c.textSecondary),
                  const SizedBox(width: SgSpace.x3),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: context.text.titleMedium),
                      if (description != null)
                        Text(description, style: context.text.bodySmall),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: SgMotion.fast,
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          key: const ValueKey(true),
                          color: c.accent,
                          size: 22,
                        )
                      : const SizedBox(key: ValueKey(false), width: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void showSgSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
