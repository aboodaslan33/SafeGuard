import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/i18n/i18n.dart';
import '../../../core/platform/secure_screen.dart';

/// Title + dots + feedback line + keypad. Shared by setup, lock and gate.
///
/// [onSubmit] receives the full PIN and returns an error message to show,
/// or null on success (the parent then navigates or changes step).
class PinEntryPanel extends StatefulWidget {
  const PinEntryPanel({
    super.key,
    required this.title,
    required this.length,
    required this.onSubmit,
    this.subtitle,
    this.leading,
    this.accessory,
    this.lockedUntil,
    this.initialError,
  });

  final String title;
  final String? subtitle;
  final int length;
  final Future<String?> Function(String pin) onSubmit;
  final Widget? leading;

  /// Small action under the keypad (length switch, "forgot PIN").
  final Widget? accessory;
  final DateTime? lockedUntil;
  final String? initialError;

  @override
  State<PinEntryPanel> createState() => _PinEntryPanelState();
}

class _PinEntryPanelState extends State<PinEntryPanel> {
  String _entered = '';
  late String? _error = widget.initialError;
  int _errorSignal = 0;
  bool _busy = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    SecureScreen.acquire();
    _syncTicker();
  }

  @override
  void didUpdateWidget(PinEntryPanel old) {
    super.didUpdateWidget(old);
    if (old.lockedUntil != widget.lockedUntil) _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    SecureScreen.release();
    super.dispose();
  }

  Duration? get _remainingLock {
    final until = widget.lockedUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  void _syncTicker() {
    _ticker?.cancel();
    if (_remainingLock == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_remainingLock == null) {
        t.cancel();
        setState(() => _error = null);
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _onDigit(String d) async {
    if (_busy || _remainingLock != null || _entered.length >= widget.length) {
      return;
    }
    setState(() {
      _entered += d;
      _error = null;
    });
    if (_entered.length < widget.length) return;

    setState(() => _busy = true);
    final pin = _entered;
    final error = await widget.onSubmit(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _entered = '';
      if (error != null) {
        _error = error;
        _errorSignal++;
      }
    });
  }

  void _onBackspace() {
    if (_busy || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final locked = _remainingLock;
    final feedback = locked != null
        ? tr(
            'حاول مجددًا بعد ${_formatDuration(locked)}',
            'Try again in ${_formatDuration(locked)}',
          )
        : _error;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 620;
        // Fills the screen when there is room (keypad pinned low, within thumb
        // reach) and scrolls when there isn't (landscape, large text).
        return SingleChildScrollView(
          child: SgContentWidth(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    children: [
                      SizedBox(height: compact ? SgSpace.x4 : SgSpace.x10),
                      if (widget.leading != null) ...[
                        widget.leading!,
                        SizedBox(height: compact ? SgSpace.x4 : SgSpace.x6),
                      ],
                      Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: context.text.headlineSmall,
                      ),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: SgSpace.x2),
                        Text(
                          widget.subtitle!,
                          textAlign: TextAlign.center,
                          style: context.text.bodyMedium,
                        ),
                      ],
                      SizedBox(height: compact ? SgSpace.x6 : SgSpace.x8),
                      PinDots(
                        length: widget.length,
                        filled: _entered.length,
                        errorSignal: _errorSignal,
                        hasError: _error != null && _entered.isEmpty,
                      ),
                      const SizedBox(height: SgSpace.x4),
                      // Reserved space so the layout never jumps.
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: SgMotion.fast,
                            child: _busy
                                ? const SizedBox.square(
                                    key: ValueKey('busy'),
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    feedback ?? '',
                                    key: ValueKey(feedback),
                                    textAlign: TextAlign.center,
                                    style: context.text.bodyMedium!.copyWith(
                                      color: locked != null
                                          ? c.warning
                                          : c.danger,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(height: SgSpace.x4),
                    ],
                  ),
                  Column(
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: PinKeypad(
                          keyHeight: compact ? 54 : 64,
                          enabled: !_busy && locked == null,
                          onDigit: _onDigit,
                          onBackspace: _onBackspace,
                        ),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 52),
                        child: Center(child: widget.accessory),
                      ),
                      const SizedBox(height: SgSpace.x2),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

String _formatDuration(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return m > 0
      ? tr('$m:$s دقيقة', '$m:$s min')
      : tr('${d.inSeconds} ثانية', '${d.inSeconds} s');
}

/// Maps a verification failure to a sentence for the feedback line.
String pinFailureMessage(AppFailure failure) {
  return switch (failure) {
    PinMismatchFailure(:final remainingAttempts) => tr(
      'الرمز غير صحيح. ${_attemptsLeft(remainingAttempts)}',
      'Incorrect PIN. ${_attemptsLeft(remainingAttempts)}',
    ),
    PinLockedFailure() => failure.message,
    _ => failure.message,
  };
}

String _attemptsLeft(int n) => switch (n) {
  1 => tr('تبقّت محاولة واحدة.', '1 attempt left.'),
  2 => tr('تبقّت محاولتان.', '2 attempts left.'),
  _ when n >= 3 && n <= 10 => tr('تبقّت $n محاولات.', '$n attempts left.'),
  _ => tr('تبقّت $n محاولة.', '$n attempts left.'),
};
