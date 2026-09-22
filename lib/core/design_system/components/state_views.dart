import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';
import 'sg_buttons.dart';

/// Shared layout for the three non-content states. They differ only in
/// tone: empty is neutral, error names the problem and offers one action,
/// loading shows nothing but a quiet indicator.
class _StateLayout extends StatelessWidget {
  const _StateLayout({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(SgSpace.x8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: SgRadius.lgAll,
                ),
                child: Icon(icon, color: iconColor, size: 26),
              ),
              const SizedBox(height: SgSpace.x5),
              Text(
                title,
                textAlign: TextAlign.center,
                style: context.text.titleLarge,
              ),
              if (message != null) ...[
                const SizedBox(height: SgSpace.x2),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium,
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: SgSpace.x6),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
  });

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _StateLayout(
      icon: icon,
      iconColor: c.textTertiary,
      iconBackground: c.surfaceSunken,
      title: title,
      message: message,
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.title,
    this.message,
    this.retryLabel,
    this.onRetry,
  });

  final String title;
  final String? message;
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _StateLayout(
      icon: Icons.error_outline_rounded,
      iconColor: c.danger,
      iconBackground: c.dangerMuted,
      title: title,
      message: message,
      action: onRetry == null
          ? null
          : SecondaryButton(
              label: retryLabel ?? 'إعادة المحاولة',
              onPressed: onRetry,
            ),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
          if (label != null) ...[
            const SizedBox(height: SgSpace.x4),
            Text(label!, style: context.text.bodyMedium),
          ],
        ],
      ),
    );
  }
}
