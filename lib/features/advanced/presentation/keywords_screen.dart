import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_guard.dart';
import '../../protection/presentation/protection_ui.dart';

/// Blocked keywords for searches made through SafeGuard.
///
/// One signal among several (keywords → built-in rules → AI). To limit
/// false positives they match whole words/phrases only, need 3+ letters,
/// and can't be digits only. Removing needs the PIN; adding needs it only
/// when protection settings are locked.
class KeywordsScreen extends StatefulWidget {
  const KeywordsScreen({super.key});

  @override
  State<KeywordsScreen> createState() => _KeywordsScreenState();
}

class _KeywordsScreenState extends State<KeywordsScreen> {
  List<CustomKeyword>? _items;
  String? _error;

  ProtectionEngine get _engine => AppScope.of(context).protection.engine;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final items = await _engine.keywords();
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } on AppFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    }
  }

  Future<void> _add() async {
    if (!await ProtectionGuard.authorize(
      context,
      loosens: false,
      reason: tr(
        'لتعديل الكلمات المحظورة (إعدادات الحماية مقفلة)',
        'to edit blocked keywords (protection settings are locked)',
      ),
    )) {
      return;
    }
    if (!mounted) return;
    final added = await showSgBottomSheet<CustomKeyword>(
      context,
      title: tr('كلمة محظورة', 'Blocked keyword'),
      subtitle: tr(
        'تُحظر عمليات البحث عبر SafeGuard التي تحتوي هذه الكلمة أو العبارة '
            'ككلمة كاملة، لا كجزء من كلمة أخرى.',
        'Searches through SafeGuard that contain this word or phrase as a whole word (not as part of another word) are blocked.',
      ),
      builder: (_) => _AddKeywordForm(engine: _engine),
    );
    if (added != null && mounted) {
      showSgSnack(
        context,
        tr('أُضيفت «${added.keyword}»', 'Added “${added.keyword}”'),
      );
      await _load();
    }
  }

  Future<void> _remove(CustomKeyword k) async {
    if (!await ProtectionGuard.authorize(
      context,
      loosens: true,
      reason: tr(
        'لإزالة «${k.keyword}» من الكلمات المحظورة',
        'to remove “${k.keyword}” from blocked keywords',
      ),
    )) {
      return;
    }
    try {
      await _engine.removeKeyword(k.id);
      await _load();
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return SgPage(
      showBack: true,
      title: tr('الكلمات المحظورة', 'Blocked keywords'),
      subtitle: tr(
        'تُطبَّق على البحث عبر SafeGuard، قبل القواعد والحماية الذكية.',
        'Applied to searches through SafeGuard, before rules and AI protection.',
      ),
      bottom: _engine.isSupported
          ? PrimaryButton(
              label: tr('إضافة كلمة', 'Add keyword'),
              icon: Icons.add_rounded,
              onPressed: _add,
            )
          : null,
      children: [
        const SizedBox(height: SgSpace.x6),
        if (_error != null)
          SizedBox(
            height: 320,
            child: ErrorState(
              title: tr('تعذّر تحميل القائمة', "Couldn't load the list"),
              message: _error,
              onRetry: _load,
            ),
          )
        else if (items == null)
          const SizedBox(height: 200, child: LoadingState())
        else if (items.isEmpty)
          SizedBox(
            height: 320,
            child: EmptyState(
              icon: Icons.text_fields_rounded,
              title: tr('لا توجد كلمات محظورة', 'No blocked keywords'),
              message: tr(
                'أضف كلمة أو عبارة لحظر البحث عنها على هذا الجهاز.',
                'Add a word or phrase to block searching for it on this device.',
              ),
            ),
          )
        else
          SgGroupedCard(
            children: [
              for (final k in items)
                _KeywordRow(keyword: k, onRemove: () => _remove(k)),
            ],
          ),
        const SizedBox(height: SgSpace.x3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
          child: Text(
            tr(
              'لا يقرأ SafeGuard ما تكتبه في التطبيقات الأخرى. الكلمات لا تُطابق '
                  'أجزاء الكلمات («ass» لا تحظر «class»)، ويجب أن تكون 3 أحرف على الأقل.',
              "SafeGuard doesn't read what you type in other apps. Keywords don't match parts of words (“ass” doesn't block “class”) and must be at least 3 letters.",
            ),
            style: context.text.bodySmall!.copyWith(
              color: context.colors.textTertiary,
            ),
          ),
        ),
      ],
    );
  }
}

class _KeywordRow extends StatelessWidget {
  const _KeywordRow({required this.keyword, required this.onRemove});

  final CustomKeyword keyword;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: SgSpace.x4,
        end: SgSpace.x1,
        top: SgSpace.x2,
        bottom: SgSpace.x2,
      ),
      child: Row(
        children: [
          SgIconWell(icon: keyword.category?.icon ?? Icons.person_pin_outlined),
          const SizedBox(width: SgSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  keyword.keyword,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.titleMedium,
                ),
                Text(
                  keyword.category?.title ?? tr('مخصص', 'Custom'),
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: tr('إزالة', 'Remove'),
            icon: Icon(
              Icons.remove_circle_outline_rounded,
              color: context.colors.textTertiary,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _AddKeywordForm extends StatefulWidget {
  const _AddKeywordForm({required this.engine});

  final ProtectionEngine engine;

  @override
  State<_AddKeywordForm> createState() => _AddKeywordFormState();
}

class _AddKeywordFormState extends State<_AddKeywordForm> {
  final _controller = TextEditingController();
  ProtectionCategory? _category;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(
        () => _error = tr('اكتب كلمة أو عبارة.', 'Type a word or phrase.'),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final k = await widget.engine.addKeyword(text, _category);
      if (mounted) Navigator.of(context).pop(k);
    } on AppFailure catch (f) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = f.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 64,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: tr('كلمة أو عبارة', 'Word or phrase'),
              errorText: _error,
              errorMaxLines: 3,
              counterText: '',
            ),
          ),
          const SizedBox(height: SgSpace.x4),
          Text(tr('الفئة', 'Category'), style: context.text.titleSmall),
          SgChoiceRow(
            label: tr('مخصص', 'Custom'),
            icon: Icons.person_pin_outlined,
            selected: _category == null,
            onTap: () => setState(() => _category = null),
          ),
          for (final c in ProtectionCategory.networkFiltered)
            SgChoiceRow(
              label: c.title,
              icon: c.icon,
              selected: c == _category,
              onTap: () => setState(() => _category = c),
            ),
          const SizedBox(height: SgSpace.x4),
          PrimaryButton(
            label: tr('إضافة', 'Add'),
            loading: _busy,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
