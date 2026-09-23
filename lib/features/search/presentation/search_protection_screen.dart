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

/// Search Protection: SafeSearch on supported engines (DNS level) and a
/// SafeGuard search box whose queries are checked on submit.
///
/// Loosening anything here (turning a switch off, lowering YouTube's mode)
/// requires the PIN; tightening never does.
class SearchProtectionScreen extends StatelessWidget {
  const SearchProtectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final protection = AppScope.of(context).protection;
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) {
        final state = protection.state;
        final preset = state.mode.isPreset;
        // NORMAL/STRICT enforce fixed search settings; show what is enforced.
        final s = preset
            ? SearchSettings(
                youtube: state.mode == ProtectionMode.strict
                    ? YouTubeMode.strict
                    : YouTubeMode.moderate,
              )
            : protection.searchSettings.copyWith(
                enabled: protection.searchProtectionEnabled,
              );
        final running = protection.snapshot.isActive;
        final c = context.colors;
        return SgPage(
          showBack: true,
          title: tr('حماية البحث', 'Search protection'),
          subtitle: tr(
            'البحث الآمن في محركات البحث، وفحص ما تبحث عنه عبر SafeGuard.',
            'SafeSearch on search engines, and checking what you search for through SafeGuard.',
          ),
          children: [
            const SizedBox(height: SgSpace.x6),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.manage_search_rounded,
                  title: tr('حماية البحث', 'Search protection'),
                  subtitle: s.enabled
                      ? tr('مفعّلة', 'On')
                      : tr('متوقفة', 'Off'),
                  switchValue: s.enabled,
                  onSwitchChanged: preset
                      ? null
                      : (v) => _update(
                          context,
                          protection,
                          s,
                          s.copyWith(enabled: v),
                        ),
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
                      'يحدد هذه الإعدادات. لتعديلها اختر الوضع «مخصص» من الشاشة الرئيسية.',
                  "The “${state.mode == ProtectionMode.strict ? 'Strict' : 'Normal'}” protection mode sets these settings. To change them, choose Custom on the home screen.",
                ),
              ),
            ],
            if (s.enabled && !running) ...[
              const SizedBox(height: SgSpace.x3),
              SgNote(
                icon: Icons.info_outline_rounded,
                color: c.info,
                background: c.infoMuted,
                text: tr(
                  'البحث الآمن يُفرض عبر اتصال VPN المحلي، وهو غير نشط الآن. '
                      'شغّل الحماية من الشاشة الرئيسية.',
                  "SafeSearch is enforced through the local VPN connection, which isn't active now. Start protection from the home screen.",
                ),
              ),
            ],
            SectionHeader(title: tr('البحث الآمن (SafeSearch)', 'SafeSearch')),
            SgGroupedCard(
              children: [
                _engineTile(
                  context,
                  protection,
                  s,
                  'Google',
                  s.google,
                  (v) => s.copyWith(google: v),
                ),
                _engineTile(
                  context,
                  protection,
                  s,
                  'Bing',
                  s.bing,
                  (v) => s.copyWith(bing: v),
                ),
                _engineTile(
                  context,
                  protection,
                  s,
                  'DuckDuckGo',
                  s.duckDuckGo,
                  (v) => s.copyWith(duckDuckGo: v),
                ),
                SecuritySettingTile(
                  icon: Icons.smart_display_outlined,
                  title: 'YouTube',
                  value: _youtubeLabel(s.youtube),
                  onTap: s.enabled && !preset
                      ? () => _pickYouTube(context, protection, s)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: SgSpace.x3),
            _Hint(
              tr(
                'يعمل عندما يستخدم المتصفح DNS النظام. ميزة «DNS الآمن» في Chrome '
                    'و«DNS الخاص» في Android بمزوّد محدد تتجاوزه، وكذلك محركات البحث الأخرى.',
                "Works when the browser uses the system DNS. Chrome's “Secure DNS” and Android's “Private DNS” with a specific provider bypass it, as do other search engines.",
              ),
            ),
            SectionHeader(title: tr('الفئات', 'Categories')),
            SgGroupedCard(
              children: [
                for (final category in ProtectionCategory.networkFiltered)
                  CategoryTile(
                    category: category,
                    active: state.isActive(category),
                    enabled: state.enabled && s.enabled && !preset,
                    onChanged: (v) =>
                        ProtectionActions.setCategory(context, category, v),
                  ),
              ],
            ),
            const SizedBox(height: SgSpace.x3),
            _Hint(
              tr(
                'الفئات نفسها تُطبَّق على فلترة الشبكة وفحص البحث.',
                'The same categories apply to network filtering and search checks.',
              ),
            ),
            SectionHeader(
              title: tr('بحث عبر SafeGuard', 'Search through SafeGuard'),
            ),
            _SafeSearchBox(enabled: state.enabled && s.enabled),
          ],
        );
      },
    );
  }

  Widget _engineTile(
    BuildContext context,
    ProtectionController protection,
    SearchSettings current,
    String name,
    bool value,
    SearchSettings Function(bool) next,
  ) {
    return SecuritySettingTile(
      icon: Icons.travel_explore_rounded,
      title: name,
      switchValue: value && current.enabled,
      onSwitchChanged:
          current.enabled &&
              !AppScope.of(context).protection.state.mode.isPreset
          ? (v) => _update(context, protection, current, next(v))
          : null,
    );
  }

  static String _youtubeLabel(YouTubeMode m) => switch (m) {
    YouTubeMode.off => tr('متوقف', 'Off'),
    YouTubeMode.moderate => tr('مقيّد (معتدل)', 'Restricted (moderate)'),
    YouTubeMode.strict => tr('مقيّد (صارم)', 'Restricted (strict)'),
  };

  Future<void> _pickYouTube(
    BuildContext context,
    ProtectionController protection,
    SearchSettings current,
  ) async {
    final picked = await showSgBottomSheet<YouTubeMode>(
      context,
      title: tr('الوضع المقيّد في YouTube', 'YouTube Restricted Mode'),
      subtitle: tr(
        'يُفرض عبر DNS على تطبيق YouTube والمتصفح.',
        'Enforced through DNS for the YouTube app and the browser.',
      ),
      builder: (context) => Column(
        children: [
          for (final m in YouTubeMode.values.reversed)
            SgChoiceRow(
              label: _youtubeLabel(m),
              selected: m == current.youtube,
              onTap: () => Navigator.of(context).pop(m),
            ),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;
    await _update(
      context,
      protection,
      current,
      current.copyWith(youtube: picked),
    );
  }

  Future<void> _update(
    BuildContext context,
    ProtectionController protection,
    SearchSettings current,
    SearchSettings next,
  ) async {
    final loosens = current.isLoosenedBy(next);
    final reason = !next.enabled
        ? tr('لإيقاف حماية البحث', 'to turn off search protection')
        : loosens
        ? tr('لتخفيف إعدادات البحث الآمن', 'to loosen SafeSearch settings')
        : tr(
            'لتعديل إعدادات البحث (إعدادات الحماية مقفلة)',
            'to change search settings (protection settings are locked)',
          );
    if (!await ProtectionGuard.authorize(
      context,
      loosens: loosens,
      reason: reason,
    )) {
      return;
    }
    final result = await protection.setSearchSettings(next);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }
}

class _SafeSearchBox extends StatefulWidget {
  const _SafeSearchBox({required this.enabled});

  final bool enabled;

  @override
  State<_SafeSearchBox> createState() => _SafeSearchBoxState();
}

class _SafeSearchBoxState extends State<_SafeSearchBox> {
  final _controller = TextEditingController();
  SearchEngineId _engine = SearchEngineId.google;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Runs once per submission — never while typing.
  Future<void> _submit() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _busy) return;
    final engine = AppScope.of(context).protection.engine;
    setState(() => _busy = true);
    try {
      final check = await engine.submitSearch(query, _engine);
      if (!mounted) return;
      if (check.blocked) {
        _controller.clear();
        await context.push(
          Uri(
            path: Routes.blocked,
            queryParameters: {
              'category': ?check.category?.id,
              'source': check.ruleType.startsWith('ai_') ? 'ai' : 'search',
              'confidence': check.confidence.toStringAsFixed(2),
              'reason': ?check.explanation?.id,
            },
          ).toString(),
        );
        if (mounted) await AppScope.of(context).protection.refreshStats();
      } else if (!check.opened) {
        showSgSnack(
          context,
          tr(
            'لا يوجد متصفح لفتح النتائج.',
            'No browser available to open the results.',
          ),
        );
      }
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SgCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            enabled: widget.enabled,
            maxLength: 200,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: tr('ابحث بأمان…', 'Search safely…'),
              counterText: '',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(height: SgSpace.x3),
          Wrap(
            spacing: SgSpace.x2,
            runSpacing: SgSpace.x2,
            children: [
              for (final e in SearchEngineId.values)
                ChoiceChip(
                  label: Text(switch (e) {
                    SearchEngineId.google => 'Google',
                    SearchEngineId.bing => 'Bing',
                    SearchEngineId.duckduckgo => 'DuckDuckGo',
                    SearchEngineId.youtube => 'YouTube',
                  }),
                  selected: e == _engine,
                  onSelected: widget.enabled
                      ? (_) => setState(() => _engine = e)
                      : null,
                ),
            ],
          ),
          const SizedBox(height: SgSpace.x4),
          PrimaryButton(
            label: tr('بحث', 'Search'),
            icon: Icons.search_rounded,
            loading: _busy,
            onPressed: widget.enabled ? _submit : null,
          ),
          const SizedBox(height: SgSpace.x3),
          Text(
            tr(
              'يُفحص البحث عند الإرسال فقط، على جهازك: القواعد أولًا ثم الحماية '
                  'الذكية. لا يُحفظ نص البحث ولا يُسجَّل؛ عند الحظر يُسجَّل رقم '
                  'القاعدة أو النموذج والفئة فقط.',
              "Searches are checked only when you submit them, on your device: rules first, then AI protection. Search text isn't saved or logged; when blocked, only the rule or model number and the category are recorded.",
            ),
            style: context.text.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Inline tinted note (info/warning) used by the Phase 3 screens.
class SgNote extends StatelessWidget {
  const SgNote({
    super.key,
    required this.icon,
    required this.color,
    required this.background,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final Color background;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SgCard(
      color: background,
      borderColor: Colors.transparent,
      radius: SgRadius.mdAll,
      padding: const EdgeInsets.symmetric(
        horizontal: SgSpace.x4,
        vertical: SgSpace.x3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: SgSpace.x3),
          Expanded(
            child: Text(
              text,
              style: context.text.bodySmall!.copyWith(
                color: context.colors.textPrimary,
              ),
            ),
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
