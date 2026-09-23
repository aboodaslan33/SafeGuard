import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
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
      title: 'الإحصاءات',
      subtitle: 'أعداد فقط، محفوظة على جهازك. يُحتفظ بالسجل 30 يومًا.',
      children: [
        const SizedBox(height: SgSpace.x6),
        SegmentedButton<_Period>(
          segments: const [
            ButtonSegment(value: _Period.today, label: Text('اليوم')),
            ButtonSegment(value: _Period.week, label: Text('7 أيام')),
            ButtonSegment(value: _Period.month, label: Text('30 يومًا')),
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
              title: 'تعذّر تحميل الإحصاءات',
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
                title: 'إجمالي المحجوب',
                value: '${w.total}',
              ),
              SecuritySettingTile(
                icon: Icons.dns_outlined,
                title: 'نطاقات محجوبة',
                value: '${w.source(EventSourceKind.dns)}',
              ),
              SecuritySettingTile(
                icon: Icons.manage_search_rounded,
                title: 'عمليات بحث محجوبة',
                subtitle: 'بالقواعد والكلمات المحظورة',
                value: '${w.source(EventSourceKind.search)}',
              ),
              SecuritySettingTile(
                icon: Icons.auto_awesome_outlined,
                title: 'حظر بالذكاء الاصطناعي',
                value: '${w.source(EventSourceKind.ai)}',
              ),
              SecuritySettingTile(
                icon: Icons.apps_rounded,
                title: 'فتح تطبيقات محمية',
                value: '${w.source(EventSourceKind.app)}',
              ),
              SecuritySettingTile(
                icon: Icons.flag_outlined,
                title: 'بلاغات حظر خاطئ',
                value: '${w.falsePositiveReports}',
              ),
            ],
          ),
          const SectionHeader(title: 'حسب الفئة'),
          SgCard(
            child: w.total == 0
                ? Text(
                    'لا يوجد حظر في هذه الفترة.',
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
                        label: 'مخصص',
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
