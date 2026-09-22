import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';

/// Numeric keypad for PIN entry.
///
/// The key grid is always laid out LTR (1-2-3 left to right) regardless of
/// app direction: that is how every phone dialer and banking app in Arabic
/// locales presents digits, and mirroring it breaks muscle memory.
class PinKeypad extends StatelessWidget {
  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.enabled = true,
    this.keyHeight = 64,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;

  /// Shrunk on short screens so the whole flow fits without scrolling.
  final double keyHeight;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', '<'],
  ];

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: AnimatedOpacity(
        duration: SgMotion.fast,
        opacity: enabled ? 1 : 0.4,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _rows)
              Row(
                children: [
                  for (final key in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(SgSpace.x1),
                        child: _buildKey(context, key),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildKey(BuildContext context, String key) {
    if (key.isEmpty) return SizedBox(height: keyHeight);
    if (key == '<') {
      return _Key(
        height: keyHeight,
        semanticLabel: 'حذف',
        onTap: enabled ? onBackspace : null,
        child: Icon(
          Icons.backspace_outlined,
          size: 22,
          color: context.colors.textSecondary,
        ),
      );
    }
    return _Key(
      height: keyHeight,
      semanticLabel: key,
      onTap: enabled ? () => onDigit(key) : null,
      child: Text(
        key,
        style: context.text.headlineSmall!.copyWith(
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.child,
    required this.onTap,
    required this.semanticLabel,
    required this.height,
  });

  final double height;
  final Widget child;
  final VoidCallback? onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: SgRadius.lgAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          highlightColor: context.colors.surfaceRaised,
          child: SizedBox(
            height: height,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// Row of dots showing how many digits were entered. Shakes horizontally and
/// turns red when [errorSignal] changes.
class PinDots extends StatefulWidget {
  const PinDots({
    super.key,
    required this.length,
    required this.filled,
    this.errorSignal = 0,
    this.hasError = false,
  });

  final int length;
  final int filled;

  /// Increment to trigger the shake animation.
  final int errorSignal;
  final bool hasError;

  @override
  State<PinDots> createState() => _PinDotsState();
}

class _PinDotsState extends State<PinDots> with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void didUpdateWidget(PinDots old) {
    super.didUpdateWidget(old);
    if (widget.errorSignal != old.errorSignal) {
      HapticFeedback.mediumImpact();
      _shake.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: 'تم إدخال ${widget.filled} من ${widget.length} أرقام',
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _shake,
        builder: (context, child) {
          final t = _shake.value;
          final dx = math.sin(t * math.pi * 6) * 10 * (1 - t);
          return Transform.translate(offset: Offset(dx, 0), child: child);
        },
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.length; i++)
                AnimatedContainer(
                  duration: SgMotion.fast,
                  curve: SgMotion.standard,
                  margin: const EdgeInsets.symmetric(horizontal: SgSpace.x2),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.hasError
                        ? c.danger
                        : i < widget.filled
                        ? c.accent
                        : Colors.transparent,
                    border: Border.all(
                      width: 1.5,
                      color: widget.hasError
                          ? c.danger
                          : i < widget.filled
                          ? c.accent
                          : c.borderStrong,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
