import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';

enum _ButtonKind { primary, secondary, danger }

/// Filled, full-width call to action. One per screen at most.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) => _SgButton(
    kind: _ButtonKind.primary,
    label: label,
    onPressed: onPressed,
    icon: icon,
    loading: loading,
  );
}

/// Quiet, outlined action that sits next to or below a [PrimaryButton].
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool destructive;
  final bool loading;

  @override
  Widget build(BuildContext context) => _SgButton(
    kind: destructive ? _ButtonKind.danger : _ButtonKind.secondary,
    label: label,
    onPressed: onPressed,
    icon: icon,
    loading: loading,
  );
}

/// Text-only action for tertiary choices ("لاحقًا", "إلغاء").
class SgTextButton extends StatelessWidget {
  const SgTextButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: c.textSecondary,
        textStyle: context.text.labelLarge,
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: SgSpace.x4),
        shape: const RoundedRectangleBorder(borderRadius: SgRadius.mdAll),
      ),
      child: Text(label),
    );
  }
}

class _SgButton extends StatelessWidget {
  const _SgButton({
    required this.kind,
    required this.label,
    required this.onPressed,
    required this.icon,
    required this.loading,
  });

  final _ButtonKind kind;
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onPressed != null && !loading;

    final (Color bg, Color fg, Color? border) = switch (kind) {
      _ButtonKind.primary => (c.accent, c.onAccent, null),
      _ButtonKind.secondary => (
        Colors.transparent,
        c.textPrimary,
        c.borderStrong,
      ),
      _ButtonKind.danger => (c.dangerMuted, c.danger, null),
    };

    final child = loading
        ? SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: SgSpace.x2),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelLarge!.copyWith(color: fg),
                ),
              ),
            ],
          );

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        duration: SgMotion.fast,
        opacity: onPressed == null ? 0.45 : 1,
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: SgRadius.mdAll,
            side: border == null ? BorderSide.none : BorderSide(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: SgSpace.x5),
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
