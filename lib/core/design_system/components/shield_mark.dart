import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';

/// SafeGuard brand mark: a split-tone shield. The filled half reads as
/// "covered", the outlined half as "watched" — one quiet symbol instead of
/// a padlock/checkmark cliché.
class ShieldMark extends StatelessWidget {
  const ShieldMark({super.key, this.size = 40, this.color, this.muted = false});

  final double size;
  final Color? color;

  /// Muted marks lose the filled half — used for the paused state.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = color ?? c.accent;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: muted ? 0 : 1),
      duration: SgMotion.slow,
      curve: SgMotion.standard,
      builder: (context, fill, _) => CustomPaint(
        size: Size(size, size * 1.12),
        painter: _ShieldPainter(color: tint, fill: fill),
      ),
    );
  }
}

class _ShieldPainter extends CustomPainter {
  _ShieldPainter({required this.color, required this.fill});

  final Color color;
  final double fill;

  static Path shieldPath(Size s) {
    final w = s.width;
    final h = s.height;
    return Path()
      ..moveTo(w * 0.5, 0)
      ..cubicTo(w * 0.66, h * 0.07, w * 0.83, h * 0.11, w, h * 0.12)
      ..lineTo(w, h * 0.47)
      ..cubicTo(w, h * 0.74, w * 0.79, h * 0.91, w * 0.5, h)
      ..cubicTo(w * 0.21, h * 0.91, 0, h * 0.74, 0, h * 0.47)
      ..lineTo(0, h * 0.12)
      ..cubicTo(w * 0.17, h * 0.11, w * 0.34, h * 0.07, w * 0.5, 0)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final inset = stroke / 2;
    final inner = Size(size.width - stroke, size.height - stroke);
    canvas.save();
    canvas.translate(inset, inset);
    final path = shieldPath(inner);

    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.12));

    if (fill > 0) {
      canvas.save();
      canvas.clipPath(path);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, inner.width / 2, inner.height),
        Paint()..color = color.withValues(alpha: fill),
      );
      canvas.restore();
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShieldPainter old) =>
      old.color != color || old.fill != fill;
}

/// Mark + wordmark lockup used in the home header and splash.
class SafeGuardWordmark extends StatelessWidget {
  const SafeGuardWordmark({super.key, this.markSize = 22, this.style});

  final double markSize;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShieldMark(size: markSize),
        SizedBox(width: markSize * 0.45),
        // Latin brand name stays LTR inside RTL layouts.
        Text(
          'SafeGuard',
          textDirection: TextDirection.ltr,
          style:
              style ??
              context.text.titleLarge!.copyWith(
                letterSpacing: 0.2,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}
