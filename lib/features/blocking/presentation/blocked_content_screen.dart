import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../ai/presentation/report_false_positive.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';

/// Shown when content is blocked. Calm and non-judgemental: it states what
/// happened and gives one way out. It never shows the blocked address or
/// query. For search/AI blocks the user can report an incorrect block.
class BlockedContentScreen extends StatefulWidget {
  const BlockedContentScreen({
    super.key,
    this.category,
    this.source,
    this.confidence = 0,
    this.explanation,
  });

  final ProtectionCategory? category;

  /// Which rule or check decided (no matched text, no model internals).
  final DecisionExplanation? explanation;

  /// Set for blocks SafeGuard decided in-app (search rules or AI).
  final EventSourceKind? source;
  final double confidence;

  @override
  State<BlockedContentScreen> createState() => _BlockedContentScreenState();
}

class _BlockedContentScreenState extends State<BlockedContentScreen> {
  bool _reported = false;

  ProtectionCategory? get category => widget.category;

  @override
  Widget build(BuildContext context) {
    final reason =
        category?.title ?? tr('محتوى غير مناسب', 'Inappropriate content');
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: SgContentWidth(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(height: SgSpace.x6),
                    _message(context, reason),
                    _backButton(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _message(BuildContext context, String reason) {
    final c = context.colors;
    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.surface,
            shape: BoxShape.circle,
            border: Border.all(color: c.border),
          ),
          child: const ShieldMark(size: 38),
        ),
        const SizedBox(height: SgSpace.x8),
        Text(
          tr('تم حظر هذا المحتوى', 'This content was blocked'),
          textAlign: TextAlign.center,
          style: context.text.headlineSmall,
        ),
        const SizedBox(height: SgSpace.x3),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SgSpace.x4,
            vertical: SgSpace.x2,
          ),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: SgRadius.pillAll,
            border: Border.all(color: c.border),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: tr('سبب الحظر: ', 'Reason: ')),
                TextSpan(
                  text: reason,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: context.text.bodyMedium,
          ),
        ),
        if (widget.explanation != null) ...[
          const SizedBox(height: SgSpace.x3),
          Text(
            widget.explanation!.reason,
            textAlign: TextAlign.center,
            style: context.text.bodySmall!.copyWith(color: c.textSecondary),
          ),
        ],
        const SizedBox(height: SgSpace.x5),
        Text(
          tr(
            'حُجبت هذه الصفحة وفق إعدادات الحماية على جهازك.',
            'This page was blocked by the protection settings on your device.',
          ),
          textAlign: TextAlign.center,
          style: context.text.bodyMedium!.copyWith(color: c.textTertiary),
        ),
      ],
    );
  }

  Widget _backButton(BuildContext context) {
    final source = widget.source;
    final category = this.category;
    return Padding(
      padding: const EdgeInsets.only(top: SgSpace.x8, bottom: SgSpace.x6),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: PrimaryButton(
              label: tr('العودة', 'Back'),
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go(Routes.home),
            ),
          ),
          if (source != null && category != null) ...[
            const SizedBox(height: SgSpace.x2),
            if (_reported)
              Text(
                tr('تم الإبلاغ. شكرًا لك.', 'Reported. Thank you.'),
                style: context.text.bodySmall,
              )
            else
              SgTextButton(
                label: tr('إبلاغ عن حظر خاطئ', 'Report a false positive'),
                onPressed: () async {
                  final ok = await reportIncorrectBlock(
                    context,
                    source: source,
                    category: category,
                    confidence: widget.confidence,
                  );
                  if (ok && mounted) setState(() => _reported = true);
                },
              ),
          ],
          SgTextButton(
            label: tr(
              'إرسال ملاحظات للمطوّر',
              'Send feedback to the developer',
            ),
            onPressed: () => context.push(
              Routes.feedbackFor(
                'false_positive',
                category: category?.id,
                source: source?.name,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
