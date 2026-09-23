import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/app_info.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../diagnostics/domain/diagnostic_report.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';
import '../domain/feedback.dart';

String feedbackTypeLabel(FeedbackType t) => switch (t) {
  FeedbackType.falsePositive => tr(
    'حظر خاطئ (حُجب شيء سليم)',
    'False positive (something harmless was blocked)',
  ),
  FeedbackType.missedContent => tr(
    'محتوى لم يُحجب',
    'Missed content (something wasn’t blocked)',
  ),
  FeedbackType.technicalProblem => tr('مشكلة تقنية', 'Technical problem'),
};

String _sourceLabel(EventSourceKind s) => switch (s) {
  EventSourceKind.dns => tr('موقع (DNS)', 'Website (DNS)'),
  EventSourceKind.search => tr('بحث', 'Search'),
  EventSourceKind.ai => tr('الذكاء الاصطناعي', 'AI'),
  EventSourceKind.app => tr('حماية التطبيقات', 'App protection'),
  EventSourceKind.manual => tr('أخرى', 'Other'),
};

/// "Report a false positive / missed content / technical problem".
///
/// The user builds the report, sees the exact text, and decides whether to
/// copy it or save it to a file. Nothing is sent by SafeGuard and nothing
/// sensitive is attached automatically (no domain, URL, query, screenshot
/// or log); diagnostics are included only if the user ticks the box.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({
    super.key,
    this.type = FeedbackType.technicalProblem,
    this.category,
    this.source,
  });

  final FeedbackType type;
  final ProtectionCategory? category;
  final EventSourceKind? source;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  late FeedbackDraft _draft = FeedbackDraft(
    type: widget.type,
    category: widget.category,
    source: widget.source,
  );
  final _description = TextEditingController();
  DiagnosticReport? _diagnostics;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _toggleDiagnostics(bool on) async {
    setState(() => _draft = _draft.copyWith(includeDiagnostics: on));
    if (!on || _diagnostics != null) return;
    final engine = AppScope.of(context).protection.engine;
    try {
      final native = engine.isSupported
          ? await engine.diagnostics()
          : const <String, Object?>{};
      if (!mounted) return;
      setState(
        () => _diagnostics = DiagnosticReport.build(
          native: native,
          appVersion: '${AppInfo.version} (${AppInfo.buildNumber})',
          flavor: AppInfo.flavor,
          buildMode: AppInfo.buildMode,
          language: I18n.current.name,
        ),
      );
    } catch (_) {
      if (mounted) {
        showSgSnack(
          context,
          tr('تعذّر جمع التشخيص.', "Couldn't collect diagnostics."),
        );
      }
    }
  }

  String get _text => _draft.toText(
    appVersion: '${AppInfo.version} (${AppInfo.buildNumber})',
    flavor: AppInfo.flavor,
    diagnostics: _diagnostics,
  );

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (mounted) {
      showSgSnack(
        context,
        tr(
          'نُسخ التقرير. الصقه في رسالة إلى الدعم.',
          'Report copied. Paste it into a message to support.',
        ),
      );
    }
  }

  Future<void> _save() async {
    final engine = AppScope.of(context).protection.engine;
    final r = await engine.saveExport(
      _text,
      fileName: 'safeguard-feedback-${_draft.type.id.replaceAll('_', '-')}.txt',
    );
    if (!mounted) return;
    showSgSnack(context, switch (r) {
      ExportResult.saved => tr('حُفظ الملف.', 'File saved.'),
      ExportResult.cancelled => tr('أُلغي الحفظ.', 'Save cancelled.'),
      ExportResult.failed => tr('تعذّر حفظ الملف.', "Couldn't save the file."),
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hints = sensitiveHints(_draft.description);
    final needsCategory = _draft.type != FeedbackType.technicalProblem;
    return SgPage(
      showBack: true,
      title: tr('إرسال ملاحظات', 'Send feedback'),
      subtitle: tr(
        'تختار بنفسك ما يُضاف. لا يُرسل SafeGuard شيئًا.',
        'You choose what is included. SafeGuard sends nothing itself.',
      ),
      children: [
        SectionHeader(title: tr('النوع', 'Type')),
        SgGroupedCard(
          children: [
            for (final t in FeedbackType.values)
              SgChoiceRow(
                label: feedbackTypeLabel(t),
                selected: _draft.type == t,
                onTap: () => setState(() => _draft = _draft.copyWith(type: t)),
              ),
          ],
        ),
        if (needsCategory) ...[
          SectionHeader(title: tr('الفئة', 'Category')),
          DropdownButtonFormField<ProtectionCategory?>(
            isExpanded: true,
            initialValue: _draft.category,
            items: [
              DropdownMenuItem(
                value: null,
                child: Text(tr('غير متأكد', 'Not sure')),
              ),
              for (final cat in ProtectionCategory.values)
                DropdownMenuItem(
                  value: cat,
                  child: Text(cat.title, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(
              () => _draft = _draft.copyWith(
                category: v,
                clearCategory: v == null,
              ),
            ),
          ),
          SectionHeader(title: tr('المصدر', 'Where')),
          DropdownButtonFormField<EventSourceKind?>(
            isExpanded: true,
            initialValue: _draft.source,
            items: [
              DropdownMenuItem(
                value: null,
                child: Text(tr('غير متأكد', 'Not sure')),
              ),
              for (final s in EventSourceKind.values)
                DropdownMenuItem(
                  value: s,
                  child: Text(_sourceLabel(s), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(
              () => _draft = _draft.copyWith(source: v, clearSource: v == null),
            ),
          ),
        ],
        SectionHeader(title: tr('الوصف (اختياري)', 'Description (optional)')),
        TextField(
          controller: _description,
          maxLines: 4,
          maxLength: FeedbackDraft.maxDescription,
          decoration: InputDecoration(
            hintText: tr(
              'ماذا حدث؟ لا تكتب كلمات مرور أو معلومات شخصية.',
              "What happened? Don't include passwords or personal information.",
            ),
          ),
          onChanged: (v) =>
              setState(() => _draft = _draft.copyWith(description: v)),
        ),
        if (hints.isNotEmpty)
          Text(
            tr(
              'تنبيه: يبدو أن الوصف يحتوي رابطًا أو بريدًا أو رقمًا طويلًا. احذفه إن لم ترد مشاركته.',
              'Note: the description seems to contain a link, email or long number. Remove it if you don’t want to share it.',
            ),
            style: context.text.bodySmall!.copyWith(color: c.warning),
          ),
        const SizedBox(height: SgSpace.x3),
        SgGroupedCard(
          children: [
            SecuritySettingTile(
              icon: Icons.bug_report_outlined,
              title: tr(
                'إرفاق معلومات التشخيص',
                'Include technical diagnostics',
              ),
              subtitle: tr(
                'حالات وأعداد وإصدارات فقط، دون مواقع أو بحث أو أسماء تطبيقات.',
                'States, counts and versions only — no sites, searches or app names.',
              ),
              switchValue: _draft.includeDiagnostics,
              onSwitchChanged: _toggleDiagnostics,
            ),
          ],
        ),
        SectionHeader(
          title: tr('ما سيُشارك بالضبط', 'Exactly what will be shared'),
        ),
        SgCard(
          child: SelectableText(
            _text,
            key: const ValueKey('feedback-preview'),
            textDirection: TextDirection.ltr,
            style: context.text.bodySmall,
          ),
        ),
        const SizedBox(height: SgSpace.x4),
        PrimaryButton(
          label: tr('نسخ التقرير', 'Copy report'),
          icon: Icons.copy_rounded,
          onPressed: _copy,
        ),
        const SizedBox(height: SgSpace.x3),
        if (AppScope.of(context).protection.engine.isSupported)
          SecondaryButton(
            label: tr('حفظ كملف', 'Save as file'),
            icon: Icons.save_alt_rounded,
            onPressed: _save,
          ),
      ],
    );
  }
}
