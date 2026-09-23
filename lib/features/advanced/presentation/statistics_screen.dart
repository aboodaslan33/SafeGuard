import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';

enum _Period { today, week, month }

/// Blocks per period, per source and per category. Counts only: no
/// domains, queries or content are shown or stored for this screen.
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  DetailedStats? _stats;
  String? _error;
  _Period _period = _Period.today;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final s = await AppScope.of(context).protection.engine
          .detailedStatistics();
      if (mounted) {
        setState(() {
          _stats = s;
          _error = null;
        });
      }
    } on AppFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final w = switch (_period) {
      _Period.today => stats?.today,
      _Period.week => stats?.last7Days,
      _Period.month => stats?.last30Days,
    };
    return SgPage(
      showBack: true,
      title: tr('الإحصاءات', 'Statistics'),
      subtitle: tr(
        'أعداد فقط، محفوظة على جهازك. يُحتفظ بالسجل 30 يومًا.',
        'Counts only, stored on your device. Retention follows your log setting.',
      ),
      children: [
        const SizedBox(height: SgSpace.x6),
        SegmentedButton<_Period>(
          segments: [
            ButtonSegment(
              value: _Period.today,
              label: Text(tr('اليوم', 'Today')),
            ),
            ButtonSegment(
              value: _Period.week,
              label: Text(tr('7 أيام', '7 days')),
            ),
            ButtonSegment(
              value: _Period.month,
              label: Text(tr('30 يومًا', '30 days')),
            ),
          ],
          selected: {_period},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _period = s.first),
        ),
        const SizedBox(height: SgSpace.x4),
        if (_error != null)
          SizedBox(
            height: 280,
            child: ErrorState(
              title: tr('تعذّر تحميل الإحصاءات', "Couldn't load statistics"),
              message: _error,
              onRetry: _load,
            ),
          )
        else if (w == null)
          const SizedBox(height: 200, child: LoadingState())
        else ...[
          SgGroupedCard(
            children: [
              SecuritySettingTile(
                icon: Icons.shield_outlined,
                title: tr('إجمالي المحجوب', 'Total blocked'),
                value: '${w.total}',
              ),
              SecuritySettingTile(
                icon: Icons.dns_outlined,
                title: tr('نطاقات محجوبة', 'Blocked domains'),
                value: '${w.source(EventSourceKind.dns)}',
              ),
              SecuritySettingTile(
                icon: Icons.manage_search_rounded,
                title: tr('عمليات بحث محجوبة', 'Blocked searches'),
                subtitle: tr(
                  'بالقواعد والكلمات المحظورة',
                  'By rules and blocked keywords',
                ),
                value: '${w.source(EventSourceKind.search)}',
              ),
              SecuritySettingTile(
                icon: Icons.auto_awesome_outlined,
                title: tr('حظر بالذكاء الاصطناعي', 'Blocked by AI'),
                value: '${w.source(EventSourceKind.ai)}',
              ),
              SecuritySettingTile(
                icon: Icons.apps_rounded,
                title: tr('فتح تطبيقات محمية', 'Protected app launches'),
                value: '${w.source(EventSourceKind.app)}',
              ),
              SecuritySettingTile(
                icon: Icons.flag_outlined,
                title: tr('بلاغات حظر خاطئ', 'False-positive reports'),
                value: '${w.falsePositiveReports}',
              ),
            ],
          ),
          SectionHeader(title: tr('حسب الفئة', 'By category')),
          SgCard(
            child: w.total == 0
                ? Text(
                    tr(
                      'لا يوجد حظر في هذه الفترة.',
                      'Nothing blocked in this period.',
                    ),
                    style: context.text.bodyMedium,
                  )
                : Column(
                    children: [
                      for (final c in ProtectionCategory.networkFiltered)
                        _Bar(
                          label: c.title,
                          value: w.byCategory[c] ?? 0,
                          total: w.total,
                        ),
                      _Bar(
                        label: tr('مخصص', 'Custom'),
                        value: w.customCategoryCount,
                        total: w.total,
                      ),
                    ],
                  ),
          ),
        ],
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.value, required this.total});

  final String label;
  final int value;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SgSpace.x1),
        child: Row(
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall,
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: SgRadius.pillAll,
                child: LinearProgressIndicator(
                  value: total == 0 ? 0 : value / total,
                  minHeight: 6,
                  color: c.accent,
                  backgroundColor: c.surfaceSunken,
                ),
              ),
            ),
            const SizedBox(width: SgSpace.x2),
            SizedBox(
              width: 40,
              child: Text(
                '$value',
                textAlign: TextAlign.end,
                style: context.text.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
