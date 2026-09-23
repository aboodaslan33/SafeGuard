import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_controller.dart';
import '../../protection/presentation/protection_guard.dart';
import '../../protection/presentation/protection_ui.dart';
import '../../search/presentation/search_protection_screen.dart' show SgNote;
import 'report_false_positive.dart';

/// AI Protection: on-device classification of searches submitted through
/// SafeGuard and of images the user chooses to check.
///
/// Loosening (turning AI off, STRICT → NORMAL, raising a threshold) needs
/// the PIN; tightening never does.
class AiProtectionScreen extends StatefulWidget {
  const AiProtectionScreen({super.key});

  @override
  State<AiProtectionScreen> createState() => _AiProtectionScreenState();
}

class _AiProtectionScreenState extends State<AiProtectionScreen> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.of(context).protection.refreshAi();
    });
  }

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) {
        final state = protection.state;
        final preset = state.mode.isPreset;
        // NORMAL/STRICT enforce AI on with their own thresholds.
        final ai = preset
            ? protection.aiSettings.copyWith(
                enabled: true,
                mode: state.mode == ProtectionMode.strict
                    ? DetectionMode.strict
                    : DetectionMode.normal,
              )
            : protection.aiSettings;
        final stats = protection.aiStatistics;
        final c = context.colors;
        return SgPage(
          showBack: true,
          title: 'الحماية الذكية',
          subtitle:
              'تصنيف المحتوى بالذكاء الاصطناعي على جهازك، دون رفع أي شيء.',
          children: [
            const SizedBox(height: SgSpace.x6),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.auto_awesome_outlined,
                  title: 'الحماية الذكية',
                  subtitle: ai.enabled ? 'مفعّلة' : 'متوقفة',
                  switchValue: ai.enabled,
                  onSwitchChanged: preset
                      ? null
                      : (v) => _update(protection, ai, ai.copyWith(enabled: v)),
                ),
              ],
            ),
            if (preset) ...[
              const SizedBox(height: SgSpace.x3),
              SgNote(
                icon: Icons.lock_outline_rounded,
                color: c.info,
                background: c.infoMuted,
                text:
                    'وضع الحماية «${state.mode == ProtectionMode.strict ? 'صارم' : 'عادي'}» '
                    'يحدد إعدادات الحماية الذكية. لتعديلها اختر الوضع «مخصص».',
              ),
            ],
            const SizedBox(height: SgSpace.x3),
            SgNote(
              icon: Icons.info_outline_rounded,
              color: c.info,
              background: c.infoMuted,
              text:
                  'تعمل عند الطلب فقط: على عمليات البحث عبر SafeGuard بعد فحص '
                  'القواعد، وعلى الصور التي تختار فحصها. لا تراقب الشاشة أو '
                  'التطبيقات الأخرى.',
            ),
            const SectionHeader(title: 'وضع الكشف'),
            SgGroupedCard(
              children: [
                for (final mode in DetectionMode.values)
                  _ModeRow(
                    mode: mode,
                    selected: ai.mode == mode,
                    enabled: ai.enabled && !preset,
                    onTap: () =>
                        _update(protection, ai, ai.copyWith(mode: mode)),
                  ),
                if (ai.mode == DetectionMode.custom && !preset)
                  SecuritySettingTile(
                    icon: Icons.tune_rounded,
                    title: 'تعديل الحدود',
                    subtitle: 'نسبة الثقة المطلوبة لكل فئة',
                    onTap: ai.enabled
                        ? () => _editThresholds(protection, ai)
                        : null,
                  ),
              ],
            ),
            const SectionHeader(title: 'الفئات'),
            SgGroupedCard(
              children: [
                for (final category in ProtectionCategory.networkFiltered)
                  CategoryTile(
                    category: category,
                    active: state.isActive(category),
                    enabled: state.enabled && ai.enabled && !preset,
                    onChanged: (v) =>
                        ProtectionActions.setCategory(context, category, v),
                  ),
              ],
            ),
            const SizedBox(height: SgSpace.x3),
            const _Hint(
              'الفئات نفسها تُطبَّق على فلترة الشبكة والبحث والتصنيف الذكي.',
            ),
            const SectionHeader(title: 'فحص صورة'),
            SgCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    ai.imageModelAvailable
                        ? 'اختر صورة لفحصها على جهازك. لا تُحفظ الصورة.'
                        : 'لا يوجد نموذج صور مثبّت في هذا الإصدار. يمكنك اختيار '
                              'صورة للتحقق من صلاحيتها، لكن لن تُصنَّف.',
                    style: context.text.bodyMedium,
                  ),
                  const SizedBox(height: SgSpace.x4),
                  SecondaryButton(
                    label: 'اختيار صورة',
                    icon: Icons.image_search_rounded,
                    loading: _checking,
                    onPressed: ai.enabled && protection.engine.isSupported
                        ? () => _checkImage(protection)
                        : null,
                  ),
                ],
              ),
            ),
            const SectionHeader(title: 'الإحصاءات'),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.radar_rounded,
                  title: 'اكتشافات',
                  value: '${stats.detections}',
                ),
                SecuritySettingTile(
                  icon: Icons.block_rounded,
                  title: 'حظر بالذكاء الاصطناعي',
                  value: '${stats.blocks}',
                ),
                SecuritySettingTile(
                  icon: Icons.flag_outlined,
                  title: 'بلاغات حظر خاطئ',
                  value: '${stats.falsePositiveReports}',
                ),
                for (final category in ProtectionCategory.networkFiltered)
                  if ((stats.detectionsByCategory[category] ?? 0) > 0)
                    SecuritySettingTile(
                      icon: category.icon,
                      title: category.title,
                      value:
                          '${stats.detectionsByCategory[category]} اكتشاف · '
                          '${stats.blocksByCategory[category] ?? 0} حظر',
                    ),
              ],
            ),
            const SizedBox(height: SgSpace.x3),
            const _Hint('تُحفظ الأعداد فقط، دون نص البحث أو الصور.'),
            const SectionHeader(title: 'النماذج'),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.text_fields_rounded,
                  title: 'نموذج النص',
                  subtitle: 'على الجهاز · مُتحقَّق من سلامته',
                  value: ai.textModelAvailable
                      ? (ai.textModelId ?? 'متاح')
                      : 'غير متاح',
                ),
                SecuritySettingTile(
                  icon: Icons.image_outlined,
                  title: 'نموذج الصور',
                  value: ai.imageModelAvailable ? 'متاح' : 'غير مثبّت',
                ),
              ],
            ),
            const SizedBox(height: SgSpace.x3),
            const _Hint(
              'النموذج صغير ومحدود الدقة: قد يفوته محتوى مخالف وقد يخطئ في '
              'محتوى سليم. النتائج غير المؤكدة لا تُحظر في الوضع العادي.',
            ),
            const SizedBox(height: SgSpace.x6),
          ],
        );
      },
    );
  }

  Future<void> _update(
    ProtectionController protection,
    AiSettings current,
    AiSettings next,
  ) async {
    final loosens = current.isLoosenedBy(next);
    final reason = !next.enabled
        ? 'لإيقاف الحماية الذكية'
        : loosens
        ? 'لتخفيف إعدادات الحماية الذكية'
        : 'لتعديل الحماية الذكية (إعدادات الحماية مقفلة)';
    if (!await ProtectionGuard.authorize(
      context,
      loosens: loosens,
      reason: reason,
    )) {
      return;
    }
    final result = await protection.setAiSettings(next);
    if (result case Err(:final failure) when mounted) {
      showSgSnack(context, failure.message);
    }
  }

  Future<void> _editThresholds(
    ProtectionController protection,
    AiSettings current,
  ) async {
    final edited = await showSgBottomSheet<Map<ProtectionCategory, double>>(
      context,
      title: 'حدود الثقة',
      subtitle:
          'يُحظر المحتوى عندما تبلغ ثقة النموذج هذا الحد أو أكثر. '
          'الحد الأقل يحظر أكثر ويخطئ أكثر.',
      builder: (context) => _ThresholdEditor(settings: current),
    );
    if (edited == null || !mounted) return;
    await _update(protection, current, current.copyWith(custom: edited));
  }

  Future<void> _checkImage(ProtectionController protection) async {
    setState(() => _checking = true);
    final ImageCheck check;
    try {
      check = await protection.engine.checkImage();
      await protection.refreshAi();
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
      return;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (!mounted || check.status == ImageCheckStatus.cancelled) return;
    await showSgBottomSheet<void>(
      context,
      title: 'نتيجة الفحص',
      builder: (context) => _ImageResult(check: check),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final DetectionMode mode;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = switch (mode) {
      DetectionMode.normal => ('عادي', 'يحظر عند الثقة العالية فقط'),
      DetectionMode.strict => ('صارم', 'حدود أقل: يحظر أكثر، وأخطاء أكثر'),
      DetectionMode.custom => ('مخصص', 'تحدد حد الثقة لكل فئة'),
    };
    return SecuritySettingTile(
      icon: selected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_unchecked_rounded,
      title: title,
      subtitle: subtitle,
      showChevron: false,
      onTap: enabled && !selected ? onTap : null,
    );
  }
}

class _ThresholdEditor extends StatefulWidget {
  const _ThresholdEditor({required this.settings});

  final AiSettings settings;

  @override
  State<_ThresholdEditor> createState() => _ThresholdEditorState();
}

class _ThresholdEditorState extends State<_ThresholdEditor> {
  late final Map<ProtectionCategory, double> _values = {
    for (final c in ProtectionCategory.networkFiltered)
      c: widget.settings.threshold(c),
  };

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in ProtectionCategory.networkFiltered) ...[
          Row(
            children: [
              Expanded(child: Text(c.title, style: context.text.titleSmall)),
              Text(
                '${(_values[c]! * 100).round()}٪',
                style: context.text.titleSmall,
              ),
            ],
          ),
          Slider(
            value: _values[c]!,
            min: s.customMin,
            max: s.customMax,
            divisions: ((s.customMax - s.customMin) * 100).round(),
            label: '${(_values[c]! * 100).round()}٪',
            semanticFormatterCallback: (v) =>
                '${c.title} ${(v * 100).round()}٪',
            onChanged: (v) => setState(() => _values[c] = s.clampCustom(v)),
          ),
        ],
        const SizedBox(height: SgSpace.x3),
        PrimaryButton(
          label: 'حفظ',
          onPressed: () => Navigator.of(context).pop(Map.of(_values)),
        ),
      ],
    );
  }
}

class _ImageResult extends StatefulWidget {
  const _ImageResult({required this.check});

  final ImageCheck check;

  @override
  State<_ImageResult> createState() => _ImageResultState();
}

class _ImageResultState extends State<_ImageResult> {
  bool _reported = false;

  @override
  Widget build(BuildContext context) {
    final check = widget.check;
    final (headline, detail) = _describe(check);
    final category = check.category;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(headline, style: context.text.titleMedium),
        const SizedBox(height: SgSpace.x2),
        Text(detail, style: context.text.bodyMedium),
        if (check.status == ImageCheckStatus.ok) ...[
          const SizedBox(height: SgSpace.x4),
          for (final c in ProtectionCategory.networkFiltered)
            _ScoreBar(label: c.title, value: check.scores[c] ?? 0),
        ],
        if (check.verdict == ContentVerdict.block &&
            category != null &&
            !_reported) ...[
          const SizedBox(height: SgSpace.x4),
          SgTextButton(
            label: 'إبلاغ عن حظر خاطئ',
            onPressed: () async {
              final ok = await reportIncorrectBlock(
                context,
                source: EventSourceKind.ai,
                category: category,
                confidence: check.confidence,
              );
              if (ok && mounted) setState(() => _reported = true);
            },
          ),
        ],
      ],
    );
  }

  static (String, String) _describe(ImageCheck c) {
    if (c.status == ImageCheckStatus.rejected) {
      return (
        'لم تُفحص الصورة',
        switch (c.error) {
          'file_too_large' => 'الملف أكبر من الحد المسموح (15 ميغابايت).',
          'dimensions_too_large' => 'أبعاد الصورة كبيرة جدًا.',
          'unsupported_type' =>
            'نوع الملف غير مدعوم. الأنواع المدعومة: JPEG وPNG وWebP.',
          'type_mismatch' => 'محتوى الملف لا يطابق نوعه المعلن.',
          'unreadable' => 'تعذّرت قراءة الملف.',
          _ => 'الملف تالف أو غير صالح.',
        },
      );
    }
    if (c.status == ImageCheckStatus.unavailable) {
      return (
        'التصنيف غير متاح',
        c.error == 'no_model'
            ? 'الصورة صالحة، لكن لا يوجد نموذج صور مثبّت في هذا الإصدار، '
                  'لذلك لم تُصنَّف. لم يُحفظ شيء.'
            : 'تعذّر التصنيف الآن. حاول لاحقًا.',
      );
    }
    return switch (c.verdict) {
      ContentVerdict.block => (
        'سيُحظر هذا المحتوى',
        'الفئة: ${c.category?.title ?? '—'} · الثقة ${(c.confidence * 100).round()}٪',
      ),
      ContentVerdict.unknown => (
        'غير مؤكد',
        'النموذج غير متأكد، ولا يُحظر المحتوى غير المؤكد في هذا الوضع.',
      ),
      ContentVerdict.allow => (
        'لا مشكلة',
        'لم يُكتشف محتوى من الفئات المفعّلة.',
      ),
    };
  }
}

class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: SgSpace.x2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: context.text.bodySmall),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: SgRadius.pillAll,
              child: LinearProgressIndicator(
                value: value.clamp(0, 1),
                minHeight: 6,
                color: c.accent,
                backgroundColor: c.surfaceSunken,
              ),
            ),
          ),
          const SizedBox(width: SgSpace.x2),
          Text('${(value * 100).round()}٪', style: context.text.bodySmall),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
      child: Text(
        text,
        style: context.text.bodySmall!.copyWith(
          color: context.colors.textTertiary,
        ),
      ),
    );
  }
}
