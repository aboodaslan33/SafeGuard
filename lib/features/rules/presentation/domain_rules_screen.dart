import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';
import '../domain/domain_input.dart';

/// Custom blocklist or allowlist.
///
/// PIN rules: opening the allowlist requires the PIN (router-level, from
/// Settings) because every entry loosens protection. On the blocklist,
/// adding is free (it tightens) and removing requires the PIN.
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
    final added = await showSgBottomSheet<DomainRule>(
      context,
      title: _isBlock ? 'حظر نطاق' : 'السماح بنطاق',
      subtitle: _isBlock
          ? 'يُحظر النطاق وجميع نطاقاته الفرعية.'
          : 'يُسمح بالنطاق ونطاقاته الفرعية حتى لو كان ضمن فئة محظورة.',
      builder: (_) => _AddDomainForm(action: widget.action, engine: _engine),
    );
    if (added != null && mounted) {
      showSgSnack(context, 'أُضيف ${added.domain}');
      await _load();
    }
  }

  Future<void> _remove(DomainRule rule) async {
    if (_isBlock &&
        !await requirePin(context, reason: 'لإزالة ${rule.domain} من الحظر')) {
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
      title: _isBlock ? 'النطاقات المحظورة' : 'النطاقات المسموحة',
      subtitle: _isBlock
          ? 'نطاقات تحظرها بنفسك، أيًا كانت إعدادات الفئات.'
          : 'استثناءات تتجاوز كل قواعد الحظر.',
      bottom: _engine.isSupported
          ? PrimaryButton(
              label: 'إضافة نطاق',
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
              title: 'تعذّر تحميل القائمة',
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
              title: _isBlock ? 'لا توجد نطاقات محظورة' : 'لا توجد استثناءات',
              message: _isBlock
                  ? 'أضف نطاقًا لحظره على هذا الجهاز.'
                  : 'أضف نطاقًا تثق به ليبقى متاحًا دائمًا.',
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
            icon: category?.icon ?? Icons.verified_outlined,
            foreground: category == null ? c.accent : c.textSecondary,
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
                  category?.title ?? 'مسموح دائمًا',
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'إزالة',
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
  ProtectionCategory _category = ProtectionCategory.sexual;
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
      setState(() => _error = 'أدخل اسم نطاق صالحًا، مثل example.com');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rule = widget.action == RuleAction.block
          ? await widget.engine.addBlockedDomain(domain, _category)
          : await widget.engine.addAllowedDomain(domain);
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
            Text('الفئة', style: context.text.titleSmall),
            const SizedBox(height: SgSpace.x1),
            for (final c in ProtectionCategory.networkFiltered)
              SgChoiceRow(
                label: c.title,
                icon: c.icon,
                selected: c == _category,
                onTap: () => setState(() => _category = c),
              ),
          ],
          const SizedBox(height: SgSpace.x4),
          PrimaryButton(label: 'إضافة', loading: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}
