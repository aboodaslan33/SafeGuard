import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
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
  });

  final ProtectionCategory? category;

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
    final reason = category?.title ?? 'محتوى غير مناسب';
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
          'تم حظر هذا المحتوى',
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
                const TextSpan(text: 'سبب الحظر: '),
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
        const SizedBox(height: SgSpace.x5),
        Text(
          'حُجبت هذه الصفحة وفق إعدادات الحماية على جهازك.',
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
              label: 'العودة',
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go(Routes.home),
            ),
          ),
          if (source != null && category != null) ...[
            const SizedBox(height: SgSpace.x2),
            if (_reported)
              Text('تم الإبلاغ. شكرًا لك.', style: context.text.bodySmall)
            else
              SgTextButton(
                label: 'إبلاغ عن حظر خاطئ',
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
        ],
      ),
    );
  }
}
