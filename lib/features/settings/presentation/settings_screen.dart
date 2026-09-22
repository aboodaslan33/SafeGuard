import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../../protection/domain/protection.dart';
import '../domain/app_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const appVersion = '1.1.0';

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([deps.settings, deps.protection]),
      builder: (context, _) {
        final settings = deps.settings.settings;
        final protection = deps.protection.state;
        final engine = deps.protection.engine;
        return SgPage(
          title: 'الإعدادات',
          children: [
            const SectionHeader(title: 'الحماية'),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.category_outlined,
                  title: 'الفئات المحجوبة',
                  value:
                      '${protection.activeNetworkCount} من '
                      '${ProtectionCategory.networkFiltered.length}',
                  onTap: () => context.go(Routes.home),
                ),
                SecuritySettingTile(
                  icon: Icons.block_rounded,
                  title: 'النطاقات المحظورة',
                  subtitle: 'حظر نطاقات تختارها بنفسك',
                  onTap: () => context.push(Routes.blocklist),
                ),
                SecuritySettingTile(
                  icon: Icons.verified_outlined,
                  title: 'النطاقات المسموحة',
                  subtitle: 'استثناءات محمية برمز PIN',
                  onTap: () => _openAllowlist(context),
                ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.history_rounded,
                    title: 'سجل الحظر',
                    onTap: () => context.push(Routes.activity),
                  ),
                SecuritySettingTile(
                  icon: Icons.shield_outlined,
                  title: 'صفحة الحظر',
                  subtitle: 'معاينة ما يظهر عند الحظر',
                  onTap: () => context.push(
                    Uri(
                      path: Routes.blocked,
                      queryParameters: {
                        'category': ProtectionCategory.gambling.id,
                      },
                    ).toString(),
                  ),
                ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.restart_alt_rounded,
                    title: 'VPN دائم التشغيل',
                    subtitle: 'ليعمل SafeGuard تلقائيًا بعد إعادة تشغيل الجهاز',
                    onTap: engine.openVpnSettings,
                  ),
              ],
            ),
            const SectionHeader(title: 'الأمان'),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.lock_outline_rounded,
                  title: 'قفل التطبيق',
                  subtitle: 'طلب الرمز عند فتح SafeGuard',
                  switchValue: settings.appLockEnabled,
                  onSwitchChanged: (v) => _setAppLock(context, v),
                ),
                SecuritySettingTile(
                  icon: Icons.password_rounded,
                  title: 'تغيير رمز PIN',
                  value: '${deps.security.pinLength} أرقام',
                  onTap: () => context.push(Routes.changePin),
                ),
              ],
            ),
            const SectionHeader(title: 'الخصوصية'),
            SgGroupedCard(
              children: [
                const SecuritySettingTile(
                  icon: Icons.phone_android_rounded,
                  title: 'البيانات على جهازك فقط',
                  subtitle:
                      'لا حساب، لا خوادم، لا تحليلات. '
                      'لا يغادر أي شيء هذا الجهاز.',
                ),
                SecuritySettingTile(
                  icon: Icons.delete_outline_rounded,
                  title: 'حذف جميع البيانات',
                  subtitle: 'يعيد SafeGuard إلى الإعداد الأولي',
                  destructive: true,
                  showChevron: false,
                  onTap: () => _eraseAll(context),
                ),
              ],
            ),
            const SectionHeader(title: 'النظام'),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.contrast_rounded,
                  title: 'المظهر',
                  value: _themeLabel(settings.theme),
                  onTap: () => _pickTheme(context, settings.theme),
                ),
                const SecuritySettingTile(
                  icon: Icons.info_outline_rounded,
                  title: 'الإصدار',
                  value: appVersion,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _themeLabel(ThemePreference t) => switch (t) {
    ThemePreference.dark => 'داكن',
    ThemePreference.light => 'فاتح',
    ThemePreference.system => 'حسب النظام',
  };

  Future<void> _openAllowlist(BuildContext context) async {
    if (!await requirePin(context, reason: 'لإدارة النطاقات المسموحة')) return;
    if (context.mounted) await context.push(Routes.allowlist);
  }

  Future<void> _setAppLock(BuildContext context, bool enabled) async {
    final deps = AppScope.of(context);
    if (!enabled && !await requirePin(context, reason: 'لإيقاف قفل التطبيق')) {
      return;
    }
    final result = await deps.settings.setAppLock(enabled);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  Future<void> _pickTheme(BuildContext context, ThemePreference current) async {
    final settings = AppScope.of(context).settings;
    final picked = await showSgBottomSheet<ThemePreference>(
      context,
      title: 'المظهر',
      builder: (context) => Column(
        children: [
          for (final (value, icon) in const [
            (ThemePreference.dark, Icons.dark_mode_outlined),
            (ThemePreference.light, Icons.light_mode_outlined),
            (ThemePreference.system, Icons.settings_suggest_outlined),
          ])
            SgChoiceRow(
              label: _themeLabel(value),
              icon: icon,
              selected: value == current,
              onTap: () => Navigator.of(context).pop(value),
            ),
        ],
      ),
    );
    if (picked == null) return;
    final result = await settings.setTheme(picked);
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
  }

  Future<void> _eraseAll(BuildContext context) async {
    final deps = AppScope.of(context);
    final confirmed = await showSgConfirmDialog(
      context,
      title: 'حذف جميع البيانات؟',
      message:
          'سيُحذف رمز PIN وجميع التفضيلات من هذا الجهاز، '
          'وسيعود التطبيق إلى الإعداد الأولي. لا يمكن التراجع عن ذلك.',
      confirmLabel: 'متابعة',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    if (!await requirePin(context, reason: 'لحذف جميع البيانات')) return;
    final result = await deps.eraseAllData();
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
    // On success the router sends the user back to onboarding.
  }
}
