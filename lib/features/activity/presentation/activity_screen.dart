import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';

/// Local block log: time, category, domain. Nothing else is recorded.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<BlockEvent>? _events;
  String? _error;

  ProtectionEngine get _engine => AppScope.of(context).protection.engine;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final events = await _engine.blockedLogs(limit: 300);
      if (mounted) {
        setState(() {
          _events = events;
          _error = null;
        });
      }
    } on AppFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showSgConfirmDialog(
      context,
      title: tr('مسح سجل الحظر؟', 'Clear block log?'),
      message: tr(
        'ستُحذف جميع الأحداث والإحصاءات المسجّلة على هذا الجهاز.',
        'All events and statistics recorded on this device will be deleted.',
      ),
      confirmLabel: tr('مسح', 'Clear'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    if (!await requirePin(
      context,
      reason: tr('لمسح سجل الحظر', 'to clear the block log'),
    )) {
      return;
    }
    try {
      await _engine.clearLogs();
      if (!mounted) return;
      await AppScope.of(context).protection.refreshStats();
      await _load();
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return SgPage(
      showBack: true,
      title: tr('سجل الحظر', 'Block log'),
      subtitle: tr(
        'الوقت والفئة والنطاق فقط. لا يُسجَّل أي محتوى.',
        'Time, category and domain only. No content is recorded.',
      ),
      children: [
        const SizedBox(height: SgSpace.x6),
        if (_error != null)
          SizedBox(
            height: 320,
            child: ErrorState(
              title: tr('تعذّر تحميل السجل', "Couldn't load the log"),
              message: _error,
              onRetry: _load,
            ),
          )
        else if (events == null)
          const SizedBox(height: 200, child: LoadingState())
        else if (events.isEmpty)
          SizedBox(
            height: 320,
            child: EmptyState(
              icon: Icons.history_rounded,
              title: tr('لا يوجد شيء محجوب بعد', 'Nothing blocked yet'),
              message: tr(
                'عندما يحجب SafeGuard نطاقًا سيظهر هنا.',
                'When SafeGuard blocks a domain, it will appear here.',
              ),
            ),
          )
        else ...[
          SgGroupedCard(
            children: [for (final e in events) _EventRow(event: e)],
          ),
          const SizedBox(height: SgSpace.x4),
          SecondaryButton(
            label: tr('مسح السجل', 'Clear log'),
            destructive: true,
            onPressed: _clear,
          ),
        ],
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final BlockEvent event;

  @override
  Widget build(BuildContext context) {
    final category = event.category;
    final t = event.time;
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hhmm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final when = sameDay ? hhmm : '${t.day}/${t.month} $hhmm';
    return InkWell(
      // Only blocks open the block screen (not e.g. a temporary unlock).
      onTap: !event.isBlock
          ? null
          : () => context.push(
              Uri(
                path: Routes.blocked,
                queryParameters: {
                  'category': ?category?.id,
                  // Search/AI blocks can be reported as incorrect from there.
                  if (event.source == EventSourceKind.search ||
                      event.source == EventSourceKind.ai) ...{
                    'source': event.source.name,
                    'confidence': event.confidence.toStringAsFixed(2),
                  },
                },
              ).toString(),
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SgSpace.x4,
          vertical: SgSpace.x3,
        ),
        child: Row(
          children: [
            SgIconWell(
              icon: switch (event.source) {
                EventSourceKind.app => Icons.apps_rounded,
                EventSourceKind.search => Icons.manage_search_rounded,
                EventSourceKind.ai => Icons.auto_awesome_outlined,
                EventSourceKind.manual => Icons.timer_outlined,
                _ => category?.icon ?? Icons.block_rounded,
              },
            ),
            const SizedBox(width: SgSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(switch (event.source) {
                    EventSourceKind.manual
                        when event.ruleType == 'temporary_unlock' =>
                      tr('إيقاف مؤقت للحماية', 'Protection paused'),
                    _ when event.isCustomCategory => tr('مخصص', 'Custom'),
                    EventSourceKind.app => tr('تطبيق محمي', 'Protected app'),
                    EventSourceKind.search => tr(
                      'بحث · ${category?.title ?? 'فئة غير معروفة'}',
                      "Search · ${category?.title ?? 'Unknown category'}",
                    ),
                    EventSourceKind.ai => tr(
                      'ذكاء اصطناعي · ${category?.title ?? 'فئة غير معروفة'}',
                      "AI · ${category?.title ?? 'Unknown category'}",
                    ),
                    _ =>
                      category?.title ??
                          tr('فئة غير معروفة', 'Unknown category'),
                  }, style: context.text.titleMedium),
                  Text(
                    // Search/AI events carry a rule or model id + hash,
                    // never the query or image.
                    event.domain,
                    textDirection: TextDirection.ltr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: SgSpace.x2),
            Text(
              when,
              textDirection: TextDirection.ltr,
              style: context.text.labelSmall!.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
