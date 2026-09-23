import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../search/presentation/search_protection_screen.dart' show SgNote;

/// Live check of the shield pipeline on this device: which stage works and
/// the first one that doesn't. Counters only (no text, queries or images),
/// refreshed every second while open.
class ShieldDiagnosticsSheet extends StatefulWidget {
  const ShieldDiagnosticsSheet({super.key, required this.engine});

  final ProtectionEngine engine;

  @override
  State<ShieldDiagnosticsSheet> createState() => _ShieldDiagnosticsSheetState();
}

class _ShieldDiagnosticsSheetState extends State<ShieldDiagnosticsSheet> {
  Map<String, Object?>? _d;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.engine.shieldDiagnostics();
      if (mounted) setState(() => _d = d);
    } on Exception {
      // Keep the last values.
    }
  }

  /// What to do about the first failing stage.
  static String verdictText(String? id) => switch (id) {
    'service_not_connected' => tr(
      'خدمة «درع المحتوى» غير متصلة. افتح إعدادات Android ← تسهيل الاستخدام ← '
          'SafeGuard AI Content Shield وفعّلها. إن كانت رمادية: معلومات التطبيق ← ⋮ ← '
          '«السماح بالإعدادات المقيدة» ثم فعّلها.',
      'The Content Shield service isn\'t connected. Open Android Settings → Accessibility → '
          'SafeGuard AI Content Shield and turn it on. If it\'s greyed out: App info → ⋮ → '
          '"Allow restricted settings", then turn it on.',
    ),
    'service_idle' => tr(
      'الخدمة متصلة لكنها متوقفة: الدرع أو الحماية أو الذكاء الاصطناعي متوقف.',
      'The service is connected but idle: the shield, protection or AI is off.',
    ),
    'no_events' => tr(
      'لم يصل أي حدث من Instagram أو Facebook أو YouTube بعد. افتح أحدها وقلّب قليلًا ثم عُد هنا. '
          'إن بقي الرقم صفرًا: أوقف الخدمة وشغّلها من جديد في إعدادات تسهيل الاستخدام، '
          'وأوقف «تحسين البطارية» لـ SafeGuard.',
      'No event has arrived from Instagram, Facebook or YouTube yet. Open one, scroll a little, '
          'then come back. If it stays at zero: turn the service off and on again in Accessibility '
          'settings, and turn off battery optimisation for SafeGuard.',
    ),
    'not_active' => tr(
      'الدرع غير نشط: راجع الحالة أعلى الشاشة.',
      'The shield isn\'t active: see the status at the top of the screen.',
    ),
    'capture_off' => tr(
      'فحص الصور متوقف، فالريلز والصور لا تُفحص (النص والبحث فقط). شغّل «فحص الصور» ووافق على تسجيل الشاشة.',
      'Image checks are off, so reels and pictures aren\'t checked (text and search only). '
          'Turn on image checks and allow screen capture.',
    ),
    'no_frames' => tr(
      'تسجيل الشاشة يعمل لكن لا تصل صور. أوقف «فحص الصور» وشغّله مجددًا.',
      'Screen capture is on but no frames arrive. Turn image checks off and on again.',
    ),
    'image_model_failed' => tr(
      'نموذج الصور لم يعمل على هذا الجهاز.',
      'The image model didn\'t run on this device.',
    ),
    _ => tr(
      'كل المراحل تعمل. إن لم يُحجب شيء، انظر «آخر نتيجة صورة»: إن كانت sexual أقل من '
          'الحد (90٪ عادي، 70٪ صارم، 60٪ أقصى حساسية) فالنموذج لم يرَه كافيًا.',
      'Every stage is working. If nothing was hidden, look at "Last image result": a sexual '
          'score under the threshold (90% normal, 70% strict, 60% maximum) means the model '
          'didn\'t see enough.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) {
      return const Padding(
        padding: EdgeInsets.all(SgSpace.x6),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    String v(String k) {
      final x = d[k];
      if (x == null) return '—';
      if (x is bool) return x ? tr('نعم', 'Yes') : tr('لا', 'No');
      return '$x';
    }

    final verdict = d['verdict'] as String?;
    final c = context.colors;
    final rows = <(String, String)>[
      (tr('الخدمة متصلة', 'Service connected'), v('serviceConnected')),
      (
        tr('أحداث من التطبيقات المدعومة', 'Events from supported apps'),
        v('eventsFromSupported'),
      ),
      (
        tr('آخر تطبيق أرسل حدثًا', 'Last app with an event'),
        v('lastEventPackage'),
      ),
      (tr('التطبيق في المقدمة', 'App in front'), v('foreground')),
      (tr('لقطات نص', 'Text snapshots'), v('textSnapshots')),
      (tr('نصوص فُحصت', 'Texts checked'), v('textChecks')),
      (tr('آخر نتيجة نص', 'Last text result'), v('lastText')),
      (tr('مربعات بحث رُصدت', 'Search boxes seen'), v('searchFields')),
      (tr('عمليات بحث فُحصت', 'Searches checked'), v('searchChecks')),
      (tr('عمليات بحث حُظرت', 'Searches blocked'), v('searchBlocks')),
      (tr('تسجيل الشاشة يعمل', 'Screen capture running'), v('captureRunning')),
      (tr('نموذج الصور', 'Image model'), v('imageModel')),
      (tr('صور وصلت', 'Frames received'), v('framesReceived')),
      (tr('صور فُحصت', 'Frames checked'), v('framesChecked')),
      (tr('آخر نتيجة صورة', 'Last image result'), v('lastImage')),
      (tr('مرات الحجب', 'Blocks'), v('blocks')),
      (tr('آخر حجب', 'Last block'), v('lastBlock')),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SgNote(
          icon: verdict == null
              ? Icons.check_circle_outline_rounded
              : Icons.error_outline_rounded,
          color: verdict == null ? c.accent : c.warning,
          background: verdict == null ? c.accentMuted : c.warningMuted,
          text: verdictText(verdict),
        ),
        const SizedBox(height: SgSpace.x4),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: SgSpace.x1),
            child: Row(
              children: [
                Expanded(child: Text(label, style: context.text.bodyMedium)),
                const SizedBox(width: SgSpace.x3),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.end,
                    textDirection: TextDirection.ltr,
                    style: context.text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: SgSpace.x3),
        Text(
          tr(
            'أرقام فقط: لا نصوص ولا صور ولا عمليات بحث. تُمسح عند إغلاق التطبيق.',
            'Numbers only: no text, images or searches. Cleared when the app closes.',
          ),
          style: context.text.bodySmall,
        ),
      ],
    );
  }
}
