import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../../../core/i18n/i18n.dart';
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
          title: tr('الحماية الذكية', 'AI protection'),
          subtitle: tr(
            'تصنيف المحتوى بالذكاء الاصطناعي على جهازك، دون رفع أي شيء.',
            'On-device AI content classification. Nothing is uploaded.',
          ),
          children: [
            const SizedBox(height: SgSpace.x6),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.auto_awesome_outlined,
                  title: tr('الحماية الذكية', 'AI protection'),
                  subtitle: ai.enabled
                      ? tr('مفعّلة', 'On')
                      : tr('متوقفة', 'Off'),
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
                text: tr(
                  'وضع الحماية «${state.mode == ProtectionMode.strict ? 'صارم' : 'عادي'}» '
                      'يحدد إعدادات الحماية الذكية. لتعديلها اختر الوضع «مخصص».',
                  "The “${state.mode == ProtectionMode.strict ? 'Strict' : 'Normal'}” protection mode sets AI protection. To change it, choose the “Custom” mode.",
                ),
              ),
            ],
            const SizedBox(height: SgSpace.x3),
            SgNote(
              icon: Icons.info_outline_rounded,
              color: c.info,
              background: c.infoMuted,
              text: tr(
                'تعمل على البحث عبر SafeGuard وعلى الصور التي تختارها. المحتوى داخل '
                    'التطبيقات يفحصه «درع المحتوى الذكي» فقط، إن فعّلته.',
                'Runs on searches through SafeGuard and images you pick. Content inside apps is checked only by the “AI Content Shield”, if you turn it on.',
              ),
            ),
            SectionHeader(title: tr('وضع الكشف', 'Detection mode')),
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
                    title: tr('تعديل الحدود', 'Adjust thresholds'),
                    subtitle: tr(
                      'نسبة الثقة المطلوبة لكل فئة',
                      'Confidence required per category',
                    ),
                    onTap: ai.enabled
                        ? () => _editThresholds(protection, ai)
                        : null,
                  ),
              ],
            ),
            SectionHeader(title: tr('الفئات', 'Categories')),
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
            _Hint(
              tr(
                'الفئات نفسها تُطبَّق على فلترة الشبكة والبحث والتصنيف الذكي.',
                'The same categories apply to network filtering, search and AI classification.',
              ),
            ),
            SectionHeader(title: tr('داخل التطبيقات', 'Inside apps')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.shield_moon_outlined,
                  title: tr('درع المحتوى الذكي', 'AI Content Shield'),
                  subtitle: tr(
                    'فحص النص الظاهر في تطبيقات مدعومة، على جهازك',
                    'Checks text shown in supported apps, on your device',
                  ),
                  onTap: () => context.push(Routes.contentShield),
                ),
              ],
            ),
            SectionHeader(title: tr('فحص صورة', 'Check an image')),
            SgCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    ai.imageModelAvailable
                        ? tr(
                            'اختر صورة لفحصها على جهازك. لا تُحفظ الصورة.',
                            "Choose an image to check on your device. The image isn't saved.",
                          )
                        : tr(
                            'لا يوجد نموذج صور مثبّت في هذا الإصدار. يمكنك اختيار '
                                'صورة للتحقق من صلاحيتها، لكن لن تُصنَّف.',
                            "No image model is installed in this version. You can choose an image to validate it, but it won't be classified.",
                          ),
                    style: context.text.bodyMedium,
                  ),
                  const SizedBox(height: SgSpace.x4),
                  SecondaryButton(
                    label: tr('اختيار صورة', 'Choose image'),
                    icon: Icons.image_search_rounded,
                    loading: _checking,
                    onPressed: ai.enabled && protection.engine.isSupported
                        ? () => _checkImage(protection)
                        : null,
                  ),
                ],
              ),
            ),
            SectionHeader(title: tr('الإحصاءات', 'Statistics')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.radar_rounded,
                  title: tr('اكتشافات', 'Detections'),
                  value: '${stats.detections}',
                ),
                SecuritySettingTile(
                  icon: Icons.block_rounded,
                  title: tr('حظر بالذكاء الاصطناعي', 'Blocked by AI'),
                  value: '${stats.blocks}',
                ),
                SecuritySettingTile(
                  icon: Icons.flag_outlined,
                  title: tr('بلاغات حظر خاطئ', 'False-positive reports'),
                  value: '${stats.falsePositiveReports}',
                ),
                for (final category in ProtectionCategory.networkFiltered)
                  if ((stats.detectionsByCategory[category] ?? 0) > 0)
                    SecuritySettingTile(
                      icon: category.icon,
                      title: category.title,
                      value: tr(
                        '${stats.detectionsByCategory[category]} اكتشاف · '
                            '${stats.blocksByCategory[category] ?? 0} حظر',
                        '${stats.detectionsByCategory[category]} detected · ${stats.blocksByCategory[category] ?? 0} blocked',
                      ),
                    ),
              ],
            ),
            const SizedBox(height: SgSpace.x3),
            _Hint(
              tr(
                'تُحفظ الأعداد فقط، دون نص البحث أو الصور.',
                'Only counts are stored, without search text or images.',
              ),
            ),
            SectionHeader(title: tr('النماذج', 'Models')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.text_fields_rounded,
                  title: tr('نموذج النص', 'Text model'),
                  subtitle: tr(
                    'على الجهاز · مُتحقَّق من سلامته',
                    'On device · integrity verified',
                  ),
                  value: ai.textModelAvailable
                      ? (ai.textModelId ?? tr('متاح', 'Available'))
                      : tr('غير متاح', 'Unavailable'),
                ),
                SecuritySettingTile(
                  icon: Icons.image_outlined,
                  title: tr('نموذج الصور', 'Image model'),
                  value: ai.imageModelAvailable
                      ? tr('متاح', 'Available')
                      : tr('غير مثبّت', 'Not installed'),
                ),
              ],
            ),
            const SizedBox(height: SgSpace.x3),
            _Hint(
              tr(
                'النموذج صغير ومحدود الدقة: قد يفوته محتوى مخالف وقد يخطئ في '
                    'محتوى سليم. النتائج غير المؤكدة لا تُحظر في الوضع العادي.',
                "The model is small with limited accuracy: it may miss harmful content and may flag harmless content. Uncertain results aren't blocked in Normal mode.",
              ),
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
        ? tr('لإيقاف الحماية الذكية', 'to turn off AI protection')
        : loosens
        ? tr(
            'لتخفيف إعدادات الحماية الذكية',
            'to loosen AI protection settings',
          )
        : tr(
            'لتعديل الحماية الذكية (إعدادات الحماية مقفلة)',
            'to change AI protection (protection settings are locked)',
          );
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
      title: tr('حدود الثقة', 'Confidence thresholds'),
      subtitle: tr(
        'يُحظر المحتوى عندما تبلغ ثقة النموذج هذا الحد أو أكثر. '
            'الحد الأقل يحظر أكثر ويخطئ أكثر.',
        "Content is blocked when the model's confidence reaches this threshold or higher. A lower threshold blocks more and makes more mistakes.",
      ),
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
      title: tr('نتيجة الفحص', 'Check result'),
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
      DetectionMode.normal => (
        tr('عادي', 'Normal'),
        tr('يحظر عند الثقة العالية فقط', 'Blocks at high confidence only'),
      ),
      DetectionMode.strict => (
        tr('صارم', 'Strict'),
        tr(
          'حدود أقل: يحظر أكثر، وأخطاء أكثر',
          'Lower thresholds: blocks more, more mistakes',
        ),
      ),
      DetectionMode.custom => (
        tr('مخصص', 'Custom'),
        tr('تحدد حد الثقة لكل فئة', 'You set the threshold per category'),
      ),
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
                tr(
                  '${(_values[c]! * 100).round()}٪',
                  '${(_values[c]! * 100).round()}%',
                ),
                style: context.text.titleSmall,
              ),
            ],
          ),
          Slider(
            value: _values[c]!,
            min: s.customMin,
            max: s.customMax,
            divisions: ((s.customMax - s.customMin) * 100).round(),
            label: tr(
              '${(_values[c]! * 100).round()}٪',
              '${(_values[c]! * 100).round()}%',
            ),
            semanticFormatterCallback: (v) => tr(
              '${c.title} ${(v * 100).round()}٪',
              '${c.title} ${(v * 100).round()}%',
            ),
            onChanged: (v) => setState(() => _values[c] = s.clampCustom(v)),
          ),
        ],
        const SizedBox(height: SgSpace.x3),
        PrimaryButton(
          label: tr('حفظ', 'Save'),
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
            label: tr('إبلاغ عن حظر خاطئ', 'Report a false positive'),
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
        tr('لم تُفحص الصورة', 'Image not checked'),
        switch (c.error) {
          'file_too_large' => tr(
            'الملف أكبر من الحد المسموح (15 ميغابايت).',
            'The file is larger than the allowed limit (15 MB).',
          ),
          'dimensions_too_large' => tr(
            'أبعاد الصورة كبيرة جدًا.',
            'The image dimensions are too large.',
          ),
          'unsupported_type' => tr(
            'نوع الملف غير مدعوم. الأنواع المدعومة: JPEG وPNG وWebP.',
            'Unsupported file type. Supported: JPEG, PNG and WebP.',
          ),
          'type_mismatch' => tr(
            'محتوى الملف لا يطابق نوعه المعلن.',
            "The file content doesn't match its declared type.",
          ),
          'unreadable' => tr('تعذّرت قراءة الملف.', "Couldn't read the file."),
          _ => tr('الملف تالف أو غير صالح.', 'The file is damaged or invalid.'),
        },
      );
    }
    if (c.status == ImageCheckStatus.unavailable) {
      return (
        tr('التصنيف غير متاح', 'Classification unavailable'),
        c.error == 'no_model'
            ? tr(
                'الصورة صالحة، لكن لا يوجد نموذج صور مثبّت في هذا الإصدار، '
                    'لذلك لم تُصنَّف. لم يُحفظ شيء.',
                "The image is valid, but no image model is installed in this version, so it wasn't classified. Nothing was saved.",
              )
            : tr(
                'تعذّر التصنيف الآن. حاول لاحقًا.',
                "Classification isn't possible right now. Try later.",
              ),
      );
    }
    return switch (c.verdict) {
      ContentVerdict.block => (
        tr('سيُحظر هذا المحتوى', 'This content would be blocked'),
        tr(
          'الفئة: ${c.category?.title ?? '—'} · الثقة ${(c.confidence * 100).round()}٪',
          "Category: ${c.category?.title ?? '—'} · confidence ${(c.confidence * 100).round()}%",
        ),
      ),
      ContentVerdict.unknown => (
        tr('غير مؤكد', 'Uncertain'),
        tr(
          'النموذج غير متأكد، ولا يُحظر المحتوى غير المؤكد في هذا الوضع.',
          "The model isn't sure, and uncertain content isn't blocked in this mode.",
        ),
      ),
      ContentVerdict.allow => (
        tr('لا مشكلة', 'No issue'),
        tr(
          'لم يُكتشف محتوى من الفئات المفعّلة.',
          'No content from the enabled categories was detected.',
        ),
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
          Text(
            tr('${(value * 100).round()}٪', '${(value * 100).round()}%'),
            style: context.text.bodySmall,
          ),
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
