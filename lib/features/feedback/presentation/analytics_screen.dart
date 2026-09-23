import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../../core/observability/crash_reporter.dart';
import '../../../core/observability/telemetry.dart';

String _eventLabel(TelemetryEvent e) => switch (e) {
  TelemetryEvent.crash => tr('أعطال التطبيق', 'App crashes'),
  TelemetryEvent.engineFailure => tr(
    'أخطاء محرك الحماية',
    'Protection engine errors',
  ),
  TelemetryEvent.vpnStartFailure => tr('فشل تشغيل VPN', 'VPN start failures'),
  TelemetryEvent.healthCheckFailure => tr(
    'فشل فحص الصحة',
    'Health check failures',
  ),
  TelemetryEvent.aiUnavailable => tr(
    'تعذّر الذكاء الاصطناعي',
    'AI unavailable',
  ),
  TelemetryEvent.storageFailure => tr('أخطاء التخزين', 'Storage errors'),
};

/// Settings → Privacy → Analytics. Both features are local: SafeGuard has
/// no analytics or crash server. The user sees exactly what is kept.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  TelemetryReport? _report;
  List<CrashRecord>? _crashes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_report == null) _load();
  }

  Future<void> _load() async {
    final deps = AppScope.of(context);
    final report = await deps.telemetry.report();
    final crashes = await deps.crashes.reports();
    if (mounted) {
      setState(() {
        _report = report;
        _crashes = crashes;
      });
    }
  }

  Future<void> _setTelemetry(bool on) async {
    await AppScope.of(context).telemetry.setEnabled(on);
    await _load();
  }

  Future<void> _setCrashes(bool on) async {
    await AppScope.of(context).crashes.setEnabled(on);
    await _load();
  }

  Future<void> _deleteCrashes() async {
    final confirmed = await showSgConfirmDialog(
      context,
      title: tr('حذف تقارير الأعطال؟', 'Delete crash reports?'),
      message: tr(
        'تُحذف تقارير الأعطال المحفوظة على هذا الجهاز.',
        'Crash reports saved on this device are deleted.',
      ),
      confirmLabel: tr('حذف', 'Delete'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await AppScope.of(context).crashes.clear();
    await _load();
  }

  Future<void> _copyCrashes() async {
    final text = [
      'SafeGuard crash reports (error types and app stack frames only)',
      for (final r in _crashes ?? const <CrashRecord>[]) r.toText(),
    ].join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showSgSnack(context, tr('نُسخت التقارير.', 'Reports copied.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    final report = _report;
    final crashes = _crashes;
    final c = context.colors;
    return SgPage(
      showBack: true,
      title: tr('التحليلات والتقارير', 'Analytics and reports'),
      subtitle: tr(
        'لا يوجد خادم تحليلات. كل ما هنا يبقى على جهازك.',
        'There is no analytics server. Everything here stays on your device.',
      ),
      children: [
        SectionHeader(title: tr('التحليلات المجهولة', 'Anonymous analytics')),
        SgGroupedCard(
          children: [
            SecuritySettingTile(
              icon: Icons.insights_outlined,
              title: tr('عدّ الأعطال والأخطاء', 'Count crashes and failures'),
              subtitle: tr(
                'متوقف افتراضيًا. عند التشغيل: أعداد يومية فقط لأنواع أخطاء محددة، دون معرّف جهاز أو محتوى. لا تُرسل.',
                'Off by default. When on: daily counts of specific error types only — no device ID, no content. Not sent.',
              ),
              switchValue: deps.telemetry.enabled,
              onSwitchChanged: _setTelemetry,
            ),
            if (deps.telemetry.enabled && report != null)
              Padding(
                padding: const EdgeInsets.all(SgSpace.x4),
                child: report.isEmpty
                    ? Text(
                        tr('لا شيء بعد.', 'Nothing yet.'),
                        style: context.text.bodySmall,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final e in TelemetryEvent.values)
                            if (report.total(e) > 0)
                              Text(
                                '${_eventLabel(e)}: ${report.total(e)}',
                                style: context.text.bodyMedium,
                              ),
                        ],
                      ),
              ),
          ],
        ),
        SectionHeader(title: tr('تقارير الأعطال', 'Crash reports')),
        SgGroupedCard(
          children: [
            SecuritySettingTile(
              icon: Icons.report_gmailerrorred_outlined,
              title: tr(
                'حفظ تقارير الأعطال على الجهاز',
                'Keep crash reports on this device',
              ),
              subtitle: tr(
                'نوع الخطأ وأماكنه في كود التطبيق، والإصدار وطراز الجهاز. دون رسائل الخطأ أو أي بيانات لك.',
                'Error type, where it happened in the app’s code, version and device model — no error messages or data of yours.',
              ),
              switchValue: deps.crashes.enabled,
              onSwitchChanged: _setCrashes,
            ),
            if (crashes != null && crashes.isNotEmpty) ...[
              for (final r in crashes.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SgSpace.x4,
                    vertical: SgSpace.x2,
                  ),
                  child: Text(
                    r.toText(),
                    textDirection: TextDirection.ltr,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall,
                  ),
                ),
              SecuritySettingTile(
                icon: Icons.copy_rounded,
                title: tr('نسخ التقارير', 'Copy reports'),
                onTap: _copyCrashes,
              ),
              SecuritySettingTile(
                icon: Icons.delete_outline_rounded,
                title: tr('حذف التقارير', 'Delete reports'),
                destructive: true,
                onTap: _deleteCrashes,
              ),
            ] else if (crashes != null)
              Padding(
                padding: const EdgeInsets.all(SgSpace.x4),
                child: Text(
                  tr('لا توجد تقارير أعطال.', 'No crash reports.'),
                  style: context.text.bodySmall!.copyWith(
                    color: c.textTertiary,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
