import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/app_info.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../domain/diagnostic_report.dart';

/// Local technical state for beta testing and support. Nothing is sent
/// anywhere: the user copies the text and decides where to paste it.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  DiagnosticReport? _report;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final protection = AppScope.of(context).protection;
    setState(() {
      _report = null;
      _failed = false;
    });
    try {
      final native = protection.engine.isSupported
          ? await protection.engine.diagnostics()
          : const <String, Object?>{};
      if (!mounted) return;
      setState(
        () => _report = DiagnosticReport.build(
          native: native,
          appVersion: '${AppInfo.version} (${AppInfo.buildNumber})',
          flavor: AppInfo.flavor,
          buildMode: AppInfo.buildMode,
          language: I18n.current.name,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _copy() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report.toText()));
    if (mounted) {
      showSgSnack(
        context,
        tr('نُسخت معلومات التشخيص.', 'Diagnostic information copied.'),
      );
    }
  }

  static String _groupTitle(String g) => switch (g) {
    'device' => tr('الجهاز', 'Device'),
    'vpn' => tr('VPN والحماية', 'VPN and protection'),
    'dns' => tr('DNS والقواعد', 'DNS and rules'),
    'features' => tr(
      'البحث والذكاء الاصطناعي والتطبيقات',
      'Search, AI and apps',
    ),
    _ => tr('النظام', 'System'),
  };

  static String _label(String key) => switch (key) {
    'appVersion' => tr('إصدار التطبيق', 'App version'),
    'flavor' => tr('نسخة البناء', 'Build flavor'),
    'buildMode' => tr('وضع البناء', 'Build mode'),
    'language' => tr('اللغة', 'Language'),
    'androidRelease' => tr('إصدار Android', 'Android version'),
    'sdkInt' => 'SDK',
    'manufacturer' => tr('الشركة المصنعة', 'Manufacturer'),
    'model' => tr('طراز الجهاز', 'Device model'),
    'protectionEnabled' => tr('الحماية مفعّلة', 'Protection enabled'),
    'vpnPermission' => tr('موافقة VPN', 'VPN consent'),
    'vpnState' => tr('حالة VPN', 'VPN status'),
    'otherVpnActive' => tr('VPN آخر نشط', 'Other VPN active'),
    'safeMode' => tr('وضع الأمان', 'Safe Mode'),
    'paused' => tr('إيقاف مؤقت', 'Paused'),
    'mode' => tr('وضع الحماية', 'Protection mode'),
    'dnsFilterActive' => tr('فلتر DNS', 'DNS filter'),
    'upstreamAvailable' => tr('خادم DNS للشبكة', 'Network DNS server'),
    'upstreamFailing' => tr('فشل خادم DNS', 'DNS server failing'),
    'privateDnsStrict' => tr('«DNS الخاص» محدد', 'Private DNS set'),
    'rulesReady' => tr('القواعد جاهزة', 'Rules ready'),
    'bundledLists' => tr('القوائم المضمّنة', 'Bundled lists'),
    'userRules' => tr('قواعد المستخدم (عدد)', 'User rules (count)'),
    'keywords' => tr('الكلمات المحظورة (عدد)', 'Blocked keywords (count)'),
    'searchEnabled' => tr('فلتر البحث', 'Search filter'),
    'aiEnabled' => tr('الحماية الذكية', 'AI protection'),
    'aiTextModel' => tr('نموذج النص', 'Text model'),
    'aiImageModel' => tr('نموذج الصور', 'Image model'),
    'protectedApps' => tr('التطبيقات المحمية (عدد)', 'Protected apps (count)'),
    'accessibility' => tr('خدمة حماية التطبيقات', 'App protection service'),
    'databaseOk' => tr('قاعدة البيانات', 'Database'),
    'logRetention' => tr('مدة السجل', 'Log retention'),
    'logWriteFailures' => tr('أخطاء كتابة السجل', 'Log write errors'),
    'batteryOptimizationIgnored' => tr(
      'مستثنى من تحسين البطارية',
      'Exempt from battery optimisation',
    ),
    'openIncidents' => tr('انقطاعات غير مراجعة', 'Unreviewed interruptions'),
    'lastBoot' => tr('آخر تشغيل بعد الإقلاع', 'Last start after boot'),
    _ => key,
  };

  @override
  Widget build(BuildContext context) {
    final report = _report;
    Widget row(String key) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SgSpace.x4,
        vertical: SgSpace.x2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(_label(key), style: context.text.bodyMedium)),
          const SizedBox(width: SgSpace.x3),
          Flexible(
            child: Text(
              report!.value(key),
              textAlign: TextAlign.end,
              // Values are technical tokens: always left-to-right.
              textDirection: TextDirection.ltr,
              style: context.text.labelMedium,
            ),
          ),
        ],
      ),
    );

    return SgPage(
      showBack: true,
      title: tr('التشخيص', 'Diagnostics'),
      subtitle: tr(
        'حالة تقنية محلية للمساعدة في حل المشكلات.',
        'Local technical state to help solve problems.',
      ),
      bottom: report == null
          ? null
          : PrimaryButton(
              label: tr('نسخ معلومات التشخيص', 'Copy diagnostic information'),
              icon: Icons.copy_rounded,
              onPressed: _copy,
            ),
      children: [
        if (_failed)
          ErrorState(
            title: tr('تعذّر جمع التشخيص', "Couldn't collect diagnostics"),
            retryLabel: tr('إعادة المحاولة', 'Try again'),
            onRetry: _load,
          )
        else if (report == null)
          const LoadingState()
        else ...[
          SectionHeader(title: tr('التطبيق', 'App')),
          SgGroupedCard(
            children: [
              for (final k in ['appVersion', 'flavor', 'buildMode', 'language'])
                row(k),
            ],
          ),
          for (final group in DiagnosticReport.fields.entries) ...[
            SectionHeader(title: _groupTitle(group.key)),
            SgGroupedCard(children: [for (final k in group.value) row(k)]),
          ],
          const SizedBox(height: SgSpace.x4),
          SgCard(
            child: Text(
              tr(
                'لا يتضمن: سجل التصفح، نصوص البحث، أسماء النطاقات أو التطبيقات، '
                    'الكلمات المحظورة، رمز PIN، الرسائل، الصور أو أي مفاتيح. '
                    'لا يُرسل شيء تلقائيًا؛ أنت من ينسخ النص ويقرر أين يلصقه.',
                'Not included: browsing history, search text, domain or app names, '
                    'blocked keywords, PIN, messages, photos or any keys. '
                    'Nothing is sent automatically; you copy the text and decide where to paste it.',
              ),
              style: context.text.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}
