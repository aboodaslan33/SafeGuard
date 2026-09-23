import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';

/// First run: one screen that states what SafeGuard does, how it treats the
/// user's data, and where its limits are — then straight into PIN setup.
/// No carousel: three swipes to learn three sentences is friction, not UX.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SgPage(
      header: Padding(
        padding: const EdgeInsets.only(top: SgSpace.x6, bottom: SgSpace.x2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ShieldMark(size: 44),
            const SizedBox(height: SgSpace.x8),
            Text(
              tr('حمايتك تبدأ\nمن جهازك', 'Protection starts\non your device'),
              style: context.text.displaySmall,
            ),
            const SizedBox(height: SgSpace.x3),
            Text(
              tr(
                'SafeGuard يحجب المحتوى غير المرغوب فيه قبل أن يصل إليك، '
                    'وتبقى إعداداتك وبياناتك على هذا الجهاز فقط.',
                'SafeGuard blocks unwanted content before it reaches you, and your settings and data stay on this device only.',
              ),
              style: context.text.bodyLarge!.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: tr('إعداد رمز PIN', 'Set up a PIN'),
            onPressed: () => context.push(Routes.createPin),
          ),
          const SizedBox(height: SgSpace.x3),
          Text(
            tr('خطوة واحدة، أقل من دقيقة.', 'One step, under a minute.'),
            textAlign: TextAlign.center,
            style: context.text.bodySmall!.copyWith(color: c.textTertiary),
          ),
        ],
      ),
      children: [
        SizedBox(height: SgSpace.x8),
        _Principle(
          icon: Icons.phone_android_rounded,
          title: tr('يعمل على جهازك', 'Runs on your device'),
          body: tr(
            'بلا حساب ولا خوادم. التفضيلات تُحفظ محليًا، والرمز مشفّر.',
            'No account, no servers. Preferences are stored locally and the PIN is encrypted.',
          ),
        ),
        _Principle(
          icon: Icons.pin_outlined,
          title: tr('محمي برمز PIN', 'PIN protected'),
          body: tr(
            'لا يمكن إيقاف الحماية أو تخفيفها دون إدخال رمزك.',
            "Protection can't be turned off or loosened without your PIN.",
          ),
        ),
        _Principle(
          icon: Icons.visibility_outlined,
          title: tr('واضح بشأن حدوده', 'Honest about its limits'),
          body: tr(
            'الفلترة تتم على مستوى الشبكة. نخبرك دائمًا بما يُحجب فعليًا وما لا يمكن حجبه.',
            "Filtering happens at the network level. We always tell you what is actually blocked and what can't be.",
          ),
        ),
      ],
    );
  }
}

class _Principle extends StatelessWidget {
  const _Principle({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SgSpace.x6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SgIconWell(icon: icon, foreground: context.colors.accent),
          const SizedBox(width: SgSpace.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleMedium),
                const SizedBox(height: 2),
                Text(body, style: context.text.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
