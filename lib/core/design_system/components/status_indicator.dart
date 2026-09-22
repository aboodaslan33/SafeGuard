import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';

enum SgStatus { active, paused, unavailable, error }

extension SgStatusColors on SgStatus {
  Color foreground(BuildContext context) {
    final c = context.colors;
    return switch (this) {
      SgStatus.active => c.accent,
      SgStatus.paused => c.warning,
      SgStatus.unavailable => c.info,
      SgStatus.error => c.danger,
    };
  }

  Color background(BuildContext context) {
    final c = context.colors;
    return switch (this) {
      SgStatus.active => c.accentMuted,
      SgStatus.paused => c.warningMuted,
      SgStatus.unavailable => c.infoMuted,
      SgStatus.error => c.dangerMuted,
    };
  }
}

/// Small pill: coloured dot + short label. Never relies on colour alone —
/// the label always states the status in words.
class StatusIndicator extends StatelessWidget {
  const StatusIndicator({
    super.key,
    required this.status,
    required this.label,
    this.dense = false,
  });

  final SgStatus status;
  final String label;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final fg = status.foreground(context);
    return AnimatedContainer(
      duration: SgMotion.medium,
      curve: SgMotion.standard,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? SgSpace.x2 : SgSpace.x3,
        vertical: dense ? 2 : SgSpace.x1,
      ),
      decoration: BoxDecoration(
        color: status.background(context),
        borderRadius: SgRadius.pillAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: fg),
          const SizedBox(width: SgSpace.x2),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  (dense ? context.text.labelSmall : context.text.labelMedium)!
                      .copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 7});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: SgMotion.medium,
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
