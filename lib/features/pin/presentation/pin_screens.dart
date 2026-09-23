import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../../../core/i18n/i18n.dart';
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
            error: tr(
              'الرمزان غير متطابقين. أعد إنشاء الرمز.',
              "The PINs don't match. Create the PIN again.",
            ),
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
          showSgSnack(context, tr('تم تغيير رمز PIN', 'PIN changed'));
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
      _SetupStep.current => (
        tr('أدخل رمزك الحالي', 'Enter your current PIN'),
        tr('للتحقق قبل تعيين رمز جديد.', 'To verify before setting a new PIN.'),
      ),
      _SetupStep.create => (
        widget.changing
            ? tr('اختر رمزًا جديدًا', 'Choose a new PIN')
            : tr('أنشئ رمز PIN', 'Create a PIN'),
        tr(
          'سيُطلب لإيقاف الحماية أو تخفيفها.',
          'It will be required to stop or loosen protection.',
        ),
      ),
      _SetupStep.confirm => (
        tr('أكّد الرمز', 'Confirm PIN'),
        tr('أدخل الرمز نفسه مرة أخرى.', 'Enter the same PIN again.'),
      ),
    };

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        title: Text(
          tr(
            'الخطوة $index من ${_steps.length}',
            'Step $index of ${_steps.length}',
          ),
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
                        ? tr('استخدم رمزًا من 4 أرقام', 'Use a 4-digit PIN')
                        : tr('استخدم رمزًا من 6 أرقام', 'Use a 6-digit PIN'),
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
            title: tr('أدخل رمز PIN', 'Enter PIN'),
            subtitle: tr('للمتابعة إلى SafeGuard', 'to continue to SafeGuard'),
            length: security.pinLength,
            lockedUntil: security.lockedUntil,
            onSubmit: (pin) async {
              final result = await security.verify(pin);
              return result.failureOrNull == null
                  ? null
                  : pinFailureMessage(result.failureOrNull!);
            },
            accessory: SgTextButton(
              label: tr('نسيت الرمز؟', 'Forgot PIN?'),
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
          tooltip: tr('إلغاء', 'Cancel'),
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.pop(false),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: security,
          builder: (context, _) => PinEntryPanel(
            title: tr('أدخل رمز PIN', 'Enter PIN'),
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
              label: tr('نسيت الرمز؟', 'Forgot PIN?'),
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
    title: tr('استعادة الوصول', 'Recover access'),
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr(
            'حتى لا يمكن تعطيل الحماية بسهولة، لا يمكن استعادة الرمز من داخل '
                'التطبيق.\n\n'
                'إذا نسيته، امسح بيانات SafeGuard من إعدادات Android: '
                'التطبيقات ← SafeGuard ← التخزين ← مسح البيانات. '
                'سيبدأ التطبيق من جديد مع تفعيل الحماية الكاملة.',
            "So protection can't be turned off easily, the PIN can't be recovered inside the app.\n\nIf you forgot it, clear SafeGuard's data in Android settings: Apps → SafeGuard → Storage → Clear data. The app starts over with full protection on.",
          ),
          style: context.text.bodyMedium,
        ),
        const SizedBox(height: SgSpace.x6),
        SecondaryButton(
          label: tr('حسنًا', 'OK'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}
