import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../../protection/domain/protection.dart';

/// "Report incorrect block". Explains exactly what is recorded, then stores
/// source, category, rounded confidence and time — on this device only.
/// Returns true if a report was recorded.
Future<bool> reportIncorrectBlock(
  BuildContext context, {
  required EventSourceKind source,
  required ProtectionCategory category,
  required double confidence,
}) async {
  final confirmed = await showSgConfirmDialog(
    context,
    title: 'الإبلاغ عن حظر خاطئ',
    message:
        'يُسجَّل على جهازك فقط: نوع الفحص والفئة ونسبة الثقة والوقت. '
        'لا يُحفظ المحتوى نفسه ولا يُرسل إلى أي مكان.',
    confirmLabel: 'إبلاغ',
  );
  if (!confirmed || !context.mounted) return false;
  final result = await AppScope.of(context).protection.reportFalsePositive(
    source: source,
    category: category,
    confidence: confidence,
  );
  if (!context.mounted) return result.isOk;
  showSgSnack(context, switch (result) {
    Ok() => 'شكرًا، سُجّل البلاغ على جهازك.',
    Err(:final failure) => failure.message,
  });
  return result.isOk;
}
