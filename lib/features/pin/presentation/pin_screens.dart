import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../domain/pin_models.dart';
import 'pin_entry_panel.dart';

enum _SetupStep { current, create, confirm }

/// Creates the first PIN (from onboarding) or changes an existing one.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key, this.changing = false});

  final bool changing;

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  late _SetupStep _step = widget.changing
      ? _SetupStep.current
      : _SetupStep.create;
  int _length = PinPolicy.defaultLength;
  String? _current;
  String? _first;
  String? _carryError;

  List<_SetupStep> get _steps => widget.changing
      ? _SetupStep.values
      : const [_SetupStep.create, _SetupStep.confirm];

  void _goTo(_SetupStep step, {String? error}) => setState(() {
    _step = step;
    _carryError = error;
  });

  Future<String?> _submit(String pin) async {
    final deps = AppScope.of(context);
    final security = deps.security;
    switch (_step) {
      case _SetupStep.current:
        final result = await security.verify(pin);
        if (result case Err(:final failure)) return pinFailureMessage(failure);
        _current = pin;
        _goTo(_SetupStep.create);
        return null;

      case _SetupStep.create:
        final invalid = PinPolicy.validate(pin);
        if (invalid != null) return invalid.message;
        _first = pin;
        _goTo(_SetupStep.confirm);
        return null;

      case _SetupStep.confirm:
        if (pin != _first) {
          _first = null;
          _goTo(
            _SetupStep.create,
            error: 'الرمزان غير متطابقين. أعد إنشاء الرمز.',
          );
          return null;
        }
        final Result<void> result = widget.changing
            ? await security.changePin(
                current: _current!,
                next: _first!,
                confirmation: pin,
              )
            : await security.createPin(_first!, pin);
        if (result case Err(:final failure)) return failure.message;

        if (!mounted) return null;
        if (widget.changing) {
          showSgSnack(context, 'تم تغيير رمز PIN');
          context.pop();
        } else {
          // Router redirect takes the user to Home once this is saved.
          final saved = await deps.settings.completeOnboarding();
          if (saved case Err(:final failure)) return failure.message;
        }
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final index = _steps.indexOf(_step) + 1;
    final (title, subtitle) = switch (_step) {
      _SetupStep.current => ('أدخل رمزك الحالي', 'للتحقق قبل تعيين رمز جديد.'),
      _SetupStep.create => (
        widget.changing ? 'اختر رمزًا جديدًا' : 'أنشئ رمز PIN',
        'سيُطلب لإيقاف الحماية أو تخفيفها.',
      ),
      _SetupStep.confirm => ('أكّد الرمز', 'أدخل الرمز نفسه مرة أخرى.'),
    };

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        title: Text(
          'الخطوة $index من ${_steps.length}',
          style: context.text.labelMedium!.copyWith(color: c.textTertiary),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: AnimatedSwitcher(
          duration: SgMotion.medium,
          child: PinEntryPanel(
            key: ValueKey('$_step-$_length'),
            title: title,
            subtitle: subtitle,
            length: _step == _SetupStep.current
                ? AppScope.of(context).security.pinLength
                : _length,
            initialError: _carryError,
            onSubmit: _submit,
            accessory: _step == _SetupStep.create
                ? SgTextButton(
                    label: _length == 6
                        ? 'استخدم رمزًا من 4 أرقام'
                        : 'استخدم رمزًا من 6 أرقام',
                    onPressed: () => setState(() {
                      _length = _length == 6 ? 4 : 6;
                      _carryError = null;
                    }),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// App lock shown on launch and after returning from background.
class PinLockScreen extends StatelessWidget {
  const PinLockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final security = AppScope.of(context).security;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: security,
          builder: (context, _) => PinEntryPanel(
            leading: const ShieldMark(size: 36),
            title: 'أدخل رمز PIN',
            subtitle: 'للمتابعة إلى SafeGuard',
            length: security.pinLength,
            lockedUntil: security.lockedUntil,
            onSubmit: (pin) async {
              final result = await security.verify(pin);
              return result.failureOrNull == null
                  ? null
                  : pinFailureMessage(result.failureOrNull!);
            },
            accessory: SgTextButton(
              label: 'نسيت الرمز؟',
              onPressed: () => _showForgotPin(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modal PIN confirmation before a sensitive action. Pops `true` on success.
class PinGateScreen extends StatelessWidget {
  const PinGateScreen({super.key, this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    final security = AppScope.of(context).security;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        leading: IconButton(
          tooltip: 'إلغاء',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.pop(false),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: security,
          builder: (context, _) => PinEntryPanel(
            title: 'أدخل رمز PIN',
            subtitle: reason,
            length: security.pinLength,
            lockedUntil: security.lockedUntil,
            onSubmit: (pin) async {
              final result = await security.verify(pin);
              if (result case Err(:final failure)) {
                return pinFailureMessage(failure);
              }
              if (context.mounted) context.pop(true);
              return null;
            },
            accessory: SgTextButton(
              label: 'نسيت الرمز؟',
              onPressed: () => _showForgotPin(context),
            ),
          ),
        ),
      ),
    );
  }
}

void _showForgotPin(BuildContext context) {
  showSgBottomSheet<void>(
    context,
    title: 'استعادة الوصول',
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'حتى لا يمكن تعطيل الحماية بسهولة، لا يمكن استعادة الرمز من داخل '
          'التطبيق.\n\n'
          'إذا نسيته، امسح بيانات SafeGuard من إعدادات Android: '
          'التطبيقات ← SafeGuard ← التخزين ← مسح البيانات. '
          'سيبدأ التطبيق من جديد مع تفعيل الحماية الكاملة.',
          style: context.text.bodyMedium,
        ),
        const SizedBox(height: SgSpace.x6),
        SecondaryButton(
          label: 'حسنًا',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}
