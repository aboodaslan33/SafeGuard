import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/i18n/i18n.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_guard.dart';
import '../../protection/presentation/protection_ui.dart';
import '../domain/domain_input.dart';

/// Custom blocklist or allowlist.
///
/// PIN rules: opening the allowlist requires the PIN (from Settings)
/// because every entry loosens protection. On the blocklist, removing
/// requires the PIN. With Protection Lock on, every change requires it.
/// Duplicates and domains already in the other list are refused.
class DomainRulesScreen extends StatefulWidget {
  const DomainRulesScreen({super.key, required this.action});

  final RuleAction action;

  @override
  State<DomainRulesScreen> createState() => _DomainRulesScreenState();
}

class _DomainRulesScreenState extends State<DomainRulesScreen> {
  List<DomainRule>? _rules;
  String? _error;

  bool get _isBlock => widget.action == RuleAction.block;
  ProtectionEngine get _engine => AppScope.of(context).protection.engine;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final rules = await _engine.userRules(widget.action);
      if (mounted) {
        setState(() {
          _rules = rules;
          _error = null;
        });
      }
    } on AppFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    }
  }

  Future<void> _add() async {
    // Adding to the blocklist tightens; it needs the PIN only when locked.
    if (_isBlock &&
        !await ProtectionGuard.authorize(
          context,
          loosens: false,
          reason: tr(
            'لتعديل قائمة الحظر (إعدادات الحماية مقفلة)',
            'to edit the blocklist (protection settings are locked)',
          ),
        )) {
      return;
    }
    if (!mounted) return;
    final added = await showSgBottomSheet<DomainRule>(
      context,
      title: _isBlock
          ? tr('حظر نطاق', 'Block a domain')
          : tr('السماح بنطاق', 'Allow a domain'),
      subtitle: _isBlock
          ? tr(
              'يُحظر النطاق وجميع نطاقاته الفرعية، أيًا كانت إعدادات الفئات.',
              'The domain and all its subdomains are blocked, whatever the category settings.',
            )
          : tr(
              'يُسمح بالنطاق حتى لو كان ضمن فئة محظورة. انتبه: السماح يتجاوز كل قواعد الحظر.',
              "The domain is allowed even if it's in a blocked category. Note: allowing overrides every block rule.",
            ),
      builder: (_) => _AddDomainForm(action: widget.action, engine: _engine),
    );
    if (added != null && mounted) {
      showSgSnack(
        context,
        tr('أُضيف ${added.domain}', 'Added ${added.domain}'),
      );
      await _load();
    }
  }

  Future<void> _remove(DomainRule rule) async {
    // Removing a block loosens; removing an exception tightens.
    if (!await ProtectionGuard.authorize(
      context,
      loosens: _isBlock,
      reason: _isBlock
          ? tr(
              'لإزالة ${rule.domain} من الحظر',
              'to remove ${rule.domain} from the blocklist',
            )
          : tr(
              'لتعديل قائمة السماح (إعدادات الحماية مقفلة)',
              'to edit the allowlist (protection settings are locked)',
            ),
    )) {
      return;
    }
    try {
      await _engine.removeRule(rule);
      await _load();
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = _rules;
    return SgPage(
      showBack: true,
      title: _isBlock
          ? tr('النطاقات المحظورة', 'Blocked domains')
          : tr('النطاقات المسموحة', 'Allowed domains'),
      subtitle: _isBlock
          ? tr(
              'نطاقات تحظرها بنفسك، أيًا كانت إعدادات الفئات.',
              'Domains you block yourself, whatever the category settings.',
            )
          : tr(
              'استثناءات تتجاوز كل قواعد الحظر.',
              'Exceptions that override every block rule.',
            ),
      bottom: _engine.isSupported
          ? PrimaryButton(
              label: tr('إضافة نطاق', 'Add domain'),
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
        else if (rules == null)
          const SizedBox(height: 200, child: LoadingState())
        else if (rules.isEmpty)
          SizedBox(
            height: 320,
            child: EmptyState(
              icon: _isBlock ? Icons.block_rounded : Icons.verified_outlined,
              title: _isBlock
                  ? tr('لا توجد نطاقات محظورة', 'No blocked domains')
                  : tr('لا توجد استثناءات', 'No exceptions'),
              message: _isBlock
                  ? tr(
                      'أضف نطاقًا لحظره على هذا الجهاز.',
                      'Add a domain to block it on this device.',
                    )
                  : tr(
                      'أضف نطاقًا تثق به ليبقى متاحًا دائمًا.',
                      'Add a domain you trust so it always stays available.',
                    ),
            ),
          )
        else
          SgGroupedCard(
            children: [
              for (final rule in rules)
                _RuleRow(rule: rule, onRemove: () => _remove(rule)),
            ],
          ),
      ],
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.rule, required this.onRemove});

  final DomainRule rule;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final category = rule.category;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: SgSpace.x4,
        end: SgSpace.x1,
        top: SgSpace.x2,
        bottom: SgSpace.x2,
      ),
      child: Row(
        children: [
          SgIconWell(
            icon: rule.action == RuleAction.allow
                ? Icons.verified_outlined
                : category?.icon ?? Icons.person_pin_outlined,
            foreground: rule.action == RuleAction.allow
                ? c.accent
                : c.textSecondary,
          ),
          const SizedBox(width: SgSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Domains are Latin: keep them LTR inside the RTL layout.
                Text(
                  rule.domain,
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.titleMedium,
                ),
                Text(
                  rule.action == RuleAction.block
                      ? (category?.title ?? tr('مخصص', 'Custom'))
                      : rule.includeSubdomains
                      ? tr(
                          'مسموح مع كل النطاقات الفرعية',
                          'Allowed with all subdomains',
                        )
                      : tr(
                          'مسموح: النطاق نفسه وwww فقط',
                          'Allowed: this domain and www only',
                        ),
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: tr('إزالة', 'Remove'),
            icon: Icon(
              Icons.remove_circle_outline_rounded,
              color: c.textTertiary,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _AddDomainForm extends StatefulWidget {
  const _AddDomainForm({required this.action, required this.engine});

  final RuleAction action;
  final ProtectionEngine engine;

  @override
  State<_AddDomainForm> createState() => _AddDomainFormState();
}

class _AddDomainFormState extends State<_AddDomainForm> {
  final _controller = TextEditingController();

  /// Null = the user's own "مخصص" category.
  ProtectionCategory? _category;
  bool _includeSubdomains = false;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final domain = DomainInput.normalize(_controller.text);
    if (domain == null) {
      setState(
        () => _error = tr(
          'أدخل اسم نطاق صالحًا، مثل example.com',
          'Enter a valid domain name, such as example.com',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rule = widget.action == RuleAction.block
          ? await widget.engine.addBlockedDomain(domain, _category)
          : await widget.engine.addAllowedDomain(
              domain,
              includeSubdomains: _includeSubdomains,
            );
      if (mounted) Navigator.of(context).pop(rule);
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
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 253,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'example.com',
              hintTextDirection: TextDirection.ltr,
              errorText: _error,
              counterText: '',
            ),
          ),
          if (widget.action == RuleAction.block) ...[
            const SizedBox(height: SgSpace.x4),
            Text(tr('الفئة', 'Category'), style: context.text.titleSmall),
            const SizedBox(height: SgSpace.x1),
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
          ],
          if (widget.action == RuleAction.allow) ...[
            const SizedBox(height: SgSpace.x2),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                tr('يشمل كل النطاقات الفرعية', 'Include all subdomains'),
              ),
              subtitle: Text(
                _includeSubdomains
                    ? tr(
                        'سيُسمح بأي عنوان ينتهي بهذا النطاق، مثل shop.example.com.',
                        'Any address ending with this domain will be allowed, such as shop.example.com.',
                      )
                    : tr(
                        'يُسمح بالنطاق نفسه وwww فقط، ولا تُفتح نطاقاته الفرعية.',
                        "Only the domain itself and www are allowed; its subdomains aren't opened.",
                      ),
              ),
              value: _includeSubdomains,
              onChanged: (v) => setState(() => _includeSubdomains = v),
            ),
          ],
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
