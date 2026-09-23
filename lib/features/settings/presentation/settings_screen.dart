import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/app_router.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/result.dart';
import '../../advanced/presentation/advanced_actions.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';
import '../domain/app_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const appVersion = '1.4.0';

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
                SecuritySettingTile(
                  icon: Icons.text_fields_rounded,
                  title: 'الكلمات المحظورة',
                  subtitle: 'كلمات تحظر البحث عبر SafeGuard',
                  onTap: () => context.push(Routes.keywords),
                ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.history_rounded,
                    title: 'سجل الحظر',
                    onTap: () => context.push(Routes.activity),
                  ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.bar_chart_rounded,
                    title: 'الإحصاءات',
                    subtitle: 'اليوم و7 أيام و30 يومًا',
                    onTap: () => context.push(Routes.statistics),
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
            const SectionHeader(title: 'الحماية المتقدمة'),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.tune_rounded,
                  title: 'وضع الحماية',
                  value: modeLabel(protection.mode),
                  onTap: () => context.go(Routes.home),
                ),
                SecuritySettingTile(
                  icon: Icons.lock_person_outlined,
                  title: 'قفل إعدادات الحماية',
                  subtitle: 'أي تغيير في الفئات والوضع والقوائم والحماية الذكية يتطلب PIN',
                  switchValue: settings.protectionLocked,
                  onSwitchChanged: (v) =>
                      AdvancedActions.setProtectionLock(context, v),
                ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.timer_outlined,
                    title: 'إيقاف مؤقت للحماية',
                    subtitle: deps.protection.isPaused
                        ? 'تُستأنف بعد ${formatCountdown(deps.protection.pauseRemaining)}'
                        : '5 أو 10 أو 30 دقيقة، برمز PIN',
                    onTap: deps.protection.isPaused
                        ? () => deps.protection.endPause()
                        : () => AdvancedActions.startTemporaryUnlock(context),
                    value: deps.protection.isPaused ? 'استئناف الآن' : null,
                  ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.health_and_safety_outlined,
                    title: 'وضع الأمان',
                    subtitle: deps.protection.healthReport.safeMode
                        ? 'مفعّل: الفلترة متوقفة. اضغط لإعادة تفعيل الحماية'
                        : 'إذا تسببت الحماية في انقطاع الإنترنت',
                    onTap: deps.protection.healthReport.safeMode
                        ? () => AdvancedActions.exitSafeMode(context)
                        : () => AdvancedActions.enterSafeMode(context),
                  ),
              ],
            ),
            const SectionHeader(title: 'البحث والتطبيقات'),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.manage_search_rounded,
                  title: 'حماية البحث',
                  subtitle: 'البحث الآمن وفحص البحث',
                  value: protection.isActive(ProtectionCategory.unsafeSearch)
                      ? 'مفعّلة'
                      : 'متوقفة',
                  onTap: () => context.push(Routes.searchProtection),
                ),
                SecuritySettingTile(
                  icon: Icons.auto_awesome_outlined,
                  title: 'الحماية الذكية',
                  subtitle: 'تصنيف المحتوى بالذكاء الاصطناعي على الجهاز',
                  onTap: () => context.push(Routes.aiProtection),
                ),
                SecuritySettingTile(
                  icon: Icons.apps_rounded,
                  title: 'حماية التطبيقات',
                  subtitle: 'منع فتح تطبيقات تختارها',
                  onTap: () => context.push(Routes.appProtection),
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
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.cleaning_services_outlined,
                    title: 'مسح سجل الحماية',
                    subtitle: 'السجل والإحصاءات والبلاغات',
                    onTap: () => AdvancedActions.clearLogs(context),
                  ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.ios_share_rounded,
                    title: 'تصدير الإعدادات',
                    subtitle: 'ملف JSON دون رمز PIN أو السجل',
                    onTap: () => AdvancedActions.exportSettings(context),
                  ),
                SecuritySettingTile(
                  icon: Icons.settings_backup_restore_rounded,
                  title: 'إعادة ضبط الحماية',
                  subtitle: 'الإعدادات الافتراضية الآمنة؛ القوائم تبقى',
                  onTap: () => AdvancedActions.resetProtection(context),
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
