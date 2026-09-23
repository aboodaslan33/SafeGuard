import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/app_info.dart';
import '../../../app/router/app_router.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/error/failures.dart';
import '../../../core/error/result.dart';
import '../../../core/i18n/i18n.dart';
import '../../advanced/presentation/advanced_actions.dart';
import '../../protection/domain/protection.dart';
import '../../protection/presentation/protection_ui.dart';
import '../domain/app_settings.dart';
import 'language_picker.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const appVersion = AppInfo.version;

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
          title: tr('الإعدادات', 'Settings'),
          children: [
            SectionHeader(title: tr('الإعداد', 'Setup')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.fact_check_outlined,
                  title: tr('مساعد الإعداد', 'Setup assistant'),
                  subtitle: tr(
                    'الأذونات وما ينقص الحماية',
                    'Permissions and what protection is missing',
                  ),
                  onTap: () => context.push(Routes.setupAssistant),
                ),
                SecuritySettingTile(
                  icon: Icons.auto_fix_high_outlined,
                  title: tr('معالج تفعيل الحماية', 'Protection setup wizard'),
                  subtitle: tr(
                    'الوضع والفئات والأذونات خطوة بخطوة',
                    'Mode, categories and permissions step by step',
                  ),
                  onTap: () => context.push(Routes.setup),
                ),
              ],
            ),
            SectionHeader(title: tr('الحماية', 'Protection')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.category_outlined,
                  title: tr('الفئات المحجوبة', 'Blocked categories'),
                  value: tr(
                    '${protection.activeNetworkCount} من '
                        '${ProtectionCategory.networkFiltered.length}',
                    '${protection.activeNetworkCount} of ${ProtectionCategory.networkFiltered.length}',
                  ),
                  onTap: () => context.push(Routes.categories),
                ),
                SecuritySettingTile(
                  icon: Icons.block_rounded,
                  title: tr('النطاقات المحظورة', 'Blocked domains'),
                  subtitle: tr(
                    'حظر نطاقات تختارها بنفسك',
                    'Block domains you choose',
                  ),
                  onTap: () => context.push(Routes.blocklist),
                ),
                SecuritySettingTile(
                  icon: Icons.verified_outlined,
                  title: tr('النطاقات المسموحة', 'Allowed domains'),
                  subtitle: tr(
                    'استثناءات محمية برمز PIN',
                    'PIN-protected exceptions',
                  ),
                  onTap: () => _openAllowlist(context),
                ),
                SecuritySettingTile(
                  icon: Icons.text_fields_rounded,
                  title: tr('الكلمات المحظورة', 'Blocked keywords'),
                  subtitle: tr(
                    'كلمات تحظر البحث عبر SafeGuard',
                    'Words that block searches through SafeGuard',
                  ),
                  onTap: () => context.push(Routes.keywords),
                ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.history_rounded,
                    title: tr('سجل الحظر', 'Block log'),
                    onTap: () => context.push(Routes.activity),
                  ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.bar_chart_rounded,
                    title: tr('الإحصاءات', 'Statistics'),
                    subtitle: tr(
                      'اليوم و7 أيام و30 يومًا',
                      'Today, 7 days and 30 days',
                    ),
                    onTap: () => context.push(Routes.statistics),
                  ),
                SecuritySettingTile(
                  icon: Icons.shield_outlined,
                  title: tr('صفحة الحظر', 'Block page'),
                  subtitle: tr(
                    'معاينة ما يظهر عند الحظر',
                    'Preview what appears when something is blocked',
                  ),
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
                    title: tr('VPN دائم التشغيل', 'Always-on VPN'),
                    subtitle: tr(
                      'ليعمل SafeGuard تلقائيًا بعد إعادة تشغيل الجهاز',
                      'So SafeGuard starts automatically after the device restarts',
                    ),
                    onTap: engine.openVpnSettings,
                  ),
                if (engine.isSupported) const _AlertsTile(),
              ],
            ),
            SectionHeader(title: tr('الحماية المتقدمة', 'Advanced protection')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.tune_rounded,
                  title: tr('وضع الحماية', 'Protection mode'),
                  value: modeLabel(protection.mode),
                  onTap: () => context.go(Routes.home),
                ),
                SecuritySettingTile(
                  icon: Icons.lock_person_outlined,
                  title: tr('قفل إعدادات الحماية', 'Protection settings lock'),
                  subtitle: tr(
                    'أي تغيير في الفئات والوضع والقوائم والحماية الذكية يتطلب PIN',
                    'Any change to categories, mode, lists or AI protection requires the PIN',
                  ),
                  switchValue: settings.protectionLocked,
                  onSwitchChanged: (v) =>
                      AdvancedActions.setProtectionLock(context, v),
                ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.timer_outlined,
                    title: tr('إيقاف مؤقت للحماية', 'Pause protection'),
                    subtitle: deps.protection.isPaused
                        ? tr(
                            'تُستأنف بعد ${formatCountdown(deps.protection.pauseRemaining)}',
                            'Resumes in ${formatCountdown(deps.protection.pauseRemaining)}',
                          )
                        : tr(
                            '5 أو 10 أو 30 دقيقة، برمز PIN',
                            '5, 10 or 30 minutes, with the PIN',
                          ),
                    onTap: deps.protection.isPaused
                        ? () => deps.protection.endPause()
                        : () => AdvancedActions.startTemporaryUnlock(context),
                    value: deps.protection.isPaused
                        ? tr('استئناف الآن', 'Resume now')
                        : null,
                  ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.health_and_safety_outlined,
                    title: tr('وضع الأمان', 'Safe Mode'),
                    subtitle: deps.protection.healthReport.safeMode
                        ? tr(
                            'مفعّل: الفلترة متوقفة. اضغط لإعادة تفعيل الحماية',
                            'On: filtering is stopped. Tap to turn protection back on',
                          )
                        : tr(
                            'إذا تسببت الحماية في انقطاع الإنترنت',
                            'If protection broke your internet connection',
                          ),
                    onTap: deps.protection.healthReport.safeMode
                        ? () => AdvancedActions.exitSafeMode(context)
                        : () => AdvancedActions.enterSafeMode(context),
                  ),
              ],
            ),
            SectionHeader(title: tr('البحث والتطبيقات', 'Search and apps')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.manage_search_rounded,
                  title: tr('حماية البحث', 'Search protection'),
                  subtitle: tr(
                    'البحث الآمن وفحص البحث',
                    'SafeSearch and search checks',
                  ),
                  value: protection.isActive(ProtectionCategory.unsafeSearch)
                      ? tr('مفعّلة', 'On')
                      : tr('متوقفة', 'Off'),
                  onTap: () => context.push(Routes.searchProtection),
                ),
                SecuritySettingTile(
                  icon: Icons.auto_awesome_outlined,
                  title: tr('الحماية الذكية', 'AI protection'),
                  subtitle: tr(
                    'تصنيف المحتوى بالذكاء الاصطناعي على الجهاز',
                    'On-device AI content classification',
                  ),
                  onTap: () => context.push(Routes.aiProtection),
                ),
                SecuritySettingTile(
                  icon: Icons.apps_rounded,
                  title: tr('حماية التطبيقات', 'App protection'),
                  subtitle: tr(
                    'منع فتح تطبيقات تختارها',
                    'Stop apps you choose from opening',
                  ),
                  onTap: () => context.push(Routes.appProtection),
                ),
              ],
            ),
            SectionHeader(title: tr('الأمان', 'Security')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.lock_outline_rounded,
                  title: tr('قفل التطبيق', 'App lock'),
                  subtitle: tr(
                    'طلب الرمز عند فتح SafeGuard',
                    'Ask for the PIN when opening SafeGuard',
                  ),
                  switchValue: settings.appLockEnabled,
                  onSwitchChanged: (v) => _setAppLock(context, v),
                ),
                SecuritySettingTile(
                  icon: Icons.password_rounded,
                  title: tr('تغيير رمز PIN', 'Change PIN'),
                  value: tr(
                    '${deps.security.pinLength} أرقام',
                    '${deps.security.pinLength} digits',
                  ),
                  onTap: () => context.push(Routes.changePin),
                ),
              ],
            ),
            SectionHeader(title: tr('الخصوصية', 'Privacy')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.phone_android_rounded,
                  title: tr(
                    'البيانات على جهازك فقط',
                    'Your data stays on your device',
                  ),
                  subtitle: tr(
                    'لا حساب، لا خوادم، لا تحليلات. '
                        'لا يغادر أي شيء هذا الجهاز.',
                    'No account, no servers, no analytics. Nothing leaves this device.',
                  ),
                ),
                if (engine.isSupported) const _LogRetentionTile(),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.cleaning_services_outlined,
                    title: tr('مسح سجل الحماية', 'Clear protection log'),
                    subtitle: tr(
                      'السجل والإحصاءات والبلاغات',
                      'Log, statistics and reports',
                    ),
                    onTap: () => AdvancedActions.clearLogs(context),
                  ),
                if (engine.isSupported)
                  SecuritySettingTile(
                    icon: Icons.ios_share_rounded,
                    title: tr('تصدير الإعدادات', 'Export settings'),
                    subtitle: tr(
                      'ملف JSON دون رمز PIN أو السجل',
                      'JSON file without the PIN or log',
                    ),
                    onTap: () => AdvancedActions.exportSettings(context),
                  ),
                SecuritySettingTile(
                  icon: Icons.settings_backup_restore_rounded,
                  title: tr('إعادة ضبط الحماية', 'Reset protection'),
                  subtitle: tr(
                    'الإعدادات الافتراضية الآمنة؛ القوائم تبقى',
                    'Secure defaults; lists are kept',
                  ),
                  onTap: () => AdvancedActions.resetProtection(context),
                ),
                SecuritySettingTile(
                  icon: Icons.delete_outline_rounded,
                  title: tr('حذف جميع البيانات', 'Delete all data'),
                  subtitle: tr(
                    'يعيد SafeGuard إلى الإعداد الأولي',
                    'Returns SafeGuard to first-run setup',
                  ),
                  destructive: true,
                  showChevron: false,
                  onTap: () => _eraseAll(context),
                ),
              ],
            ),
            SectionHeader(title: tr('النظام', 'System')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.contrast_rounded,
                  title: tr('المظهر', 'Appearance'),
                  value: _themeLabel(settings.theme),
                  onTap: () => _pickTheme(context, settings.theme),
                ),
                SecuritySettingTile(
                  icon: Icons.translate_rounded,
                  title: tr('اللغة', 'Language'),
                  value: languageLabel(settings.language),
                  onTap: () => pickLanguage(context),
                ),
                SecuritySettingTile(
                  icon: Icons.info_outline_rounded,
                  title: tr('الإصدار', 'Version'),
                  value: appVersion,
                  onTap: () => context.push(Routes.about),
                ),
              ],
            ),
            SectionHeader(title: tr('المساعدة والمعلومات', 'Help and info')),
            SgGroupedCard(
              children: [
                SecuritySettingTile(
                  icon: Icons.help_outline_rounded,
                  title: tr('المساعدة', 'Help'),
                  onTap: () => context.push(Routes.help),
                ),
                SecuritySettingTile(
                  icon: Icons.privacy_tip_outlined,
                  title: tr('الخصوصية وبياناتك', 'Privacy and your data'),
                  onTap: () => context.push(Routes.privacy),
                ),
                SecuritySettingTile(
                  icon: Icons.feedback_outlined,
                  title: tr('إرسال ملاحظات', 'Send feedback'),
                  subtitle: tr(
                    'حظر خاطئ، محتوى لم يُحجب، أو مشكلة تقنية',
                    'False positive, missed content, or a technical problem',
                  ),
                  onTap: () => context.push(Routes.feedback),
                ),
                SecuritySettingTile(
                  icon: Icons.insights_outlined,
                  title: tr('التحليلات والتقارير', 'Analytics and reports'),
                  subtitle: tr(
                    'متوقفة افتراضيًا؛ تبقى على جهازك',
                    'Off by default; stays on your device',
                  ),
                  onTap: () => context.push(Routes.analytics),
                ),
                SecuritySettingTile(
                  icon: Icons.bug_report_outlined,
                  title: tr('التشخيص', 'Diagnostics'),
                  subtitle: tr(
                    'للاختبار والدعم، دون بيانات شخصية',
                    'For testing and support, no personal data',
                  ),
                  onTap: () => context.push(Routes.diagnostics),
                ),
                SecuritySettingTile(
                  icon: Icons.shield_outlined,
                  title: tr('حول SafeGuard', 'About SafeGuard'),
                  onTap: () => context.push(Routes.about),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _themeLabel(ThemePreference t) => switch (t) {
    ThemePreference.dark => tr('داكن', 'Dark'),
    ThemePreference.light => tr('فاتح', 'Light'),
    ThemePreference.system => tr('حسب النظام', 'System default'),
  };

  Future<void> _openAllowlist(BuildContext context) async {
    if (!await requirePin(
      context,
      reason: tr('لإدارة النطاقات المسموحة', 'to manage allowed domains'),
    )) {
      return;
    }
    if (context.mounted) await context.push(Routes.allowlist);
  }

  Future<void> _setAppLock(BuildContext context, bool enabled) async {
    final deps = AppScope.of(context);
    if (!enabled &&
        !await requirePin(
          context,
          reason: tr('لإيقاف قفل التطبيق', 'to turn off app lock'),
        )) {
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
      title: tr('المظهر', 'Appearance'),
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
      title: tr('حذف جميع البيانات؟', 'Delete all data?'),
      message: tr(
        'سيُحذف رمز PIN وجميع التفضيلات من هذا الجهاز، '
            'وسيعود التطبيق إلى الإعداد الأولي. لا يمكن التراجع عن ذلك.',
        "Your PIN and all preferences will be deleted from this device, and the app will return to first-run setup. This can't be undone.",
      ),
      confirmLabel: tr('متابعة', 'Continue'),
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    if (!await requirePin(
      context,
      reason: tr('لحذف جميع البيانات', 'to delete all data'),
    )) {
      return;
    }
    final result = await deps.eraseAllData();
    if (result case Err(:final failure) when context.mounted) {
      showSgSnack(context, failure.message);
    }
    // On success the router sends the user back to onboarding.
  }
}

/// Shows and changes the activity-log retention (Phase 6).
class _LogRetentionTile extends StatefulWidget {
  const _LogRetentionTile();

  @override
  State<_LogRetentionTile> createState() => _LogRetentionTileState();
}

class _LogRetentionTileState extends State<_LogRetentionTile> {
  LogRetention? _value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_value == null) _load();
  }

  Future<void> _load() async {
    try {
      final v = await AppScope.of(context).protection.engine.logRetention();
      if (mounted) setState(() => _value = v);
    } on Object {
      // Leave the tile without a value; changing it will report the error.
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _value ?? LogRetention.defaultValue;
    return SecuritySettingTile(
      icon: Icons.history_toggle_off_rounded,
      title: tr('مدة الاحتفاظ بالسجل', 'Log retention'),
      value: _value?.label,
      onTap: () async {
        final applied = await AdvancedActions.chooseLogRetention(
          context,
          current,
        );
        if (applied != null && mounted) setState(() => _value = applied);
      },
    );
  }
}

/// "Alert me when protection stops" (Phase 8). Turning it off needs the
/// PIN: the alert is how a parent learns protection was switched off.
class _AlertsTile extends StatefulWidget {
  const _AlertsTile();

  @override
  State<_AlertsTile> createState() => _AlertsTileState();
}

class _AlertsTileState extends State<_AlertsTile> {
  AlertsState? _state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_state == null) _load();
  }

  Future<void> _load() async {
    try {
      final s = await AppScope.of(context).protection.engine.alertsState();
      if (mounted) setState(() => _state = s);
    } on Object {
      // Leave the switch in its default position.
    }
  }

  Future<void> _set(bool on) async {
    final engine = AppScope.of(context).protection.engine;
    if (!on &&
        !await requirePin(
          context,
          reason: tr(
            'لإيقاف تنبيهات توقف الحماية',
            'to turn off protection alerts',
          ),
        )) {
      return;
    }
    try {
      var next = await engine.setAlertsEnabled(on);
      if (on && !next.permission) {
        await engine.requestNotificationPermission();
        next = await engine.alertsState();
      }
      if (mounted) setState(() => _state = next);
    } on AppFailure catch (f) {
      if (mounted) showSgSnack(context, f.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state ?? const AlertsState();
    return SecuritySettingTile(
      icon: Icons.notifications_active_outlined,
      title: tr('تنبيه عند توقف الحماية', 'Alert when protection stops'),
      subtitle: s.enabled && !s.permission
          ? tr(
              'الإشعارات غير مسموحة؛ لن يظهر التنبيه',
              "Notifications aren't allowed; the alert can't appear",
            )
          : tr(
              'إشعار واحد عندما تتوقف الحماية أو تضعف',
              'One notification when protection stops or weakens',
            ),
      switchValue: s.enabled,
      onSwitchChanged: _set,
    );
  }
}
