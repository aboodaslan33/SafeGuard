import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../settings/presentation/language_picker.dart';

class _Page {
  const _Page(this.icon, this.title, this.body, [this.points = const []]);
  final IconData icon;
  final String title;
  final String body;
  final List<String> points;
}

/// First run: eight short pages — what SafeGuard does, each protection
/// layer, permissions, local data, limits, and how to turn it on — then
/// PIN setup. "Skip" jumps to the last page; nothing is hidden behind it.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  static List<_Page> get _pages => [
    _Page(
      Icons.shield_outlined,
      tr('حمايتك تبدأ من جهازك', 'Protection starts on your device'),
      tr(
        'SafeGuard يحجب المواقع والبحث غير المرغوب فيه على مستوى الجهاز، دون حساب ولا خوادم.',
        'SafeGuard blocks unwanted sites and searches at the device level, with no account and no servers.',
      ),
      [
        tr('فلترة الشبكة (DNS)', 'Network (DNS) filtering'),
        tr('حماية البحث', 'Search protection'),
        tr('حماية التطبيقات', 'App protection'),
        tr('تصنيف ذكي على الجهاز', 'On-device AI classification'),
      ],
    ),
    _Page(
      Icons.dns_outlined,
      tr('حماية الشبكة (DNS)', 'Network (DNS) protection'),
      tr(
        'قبل أن يتصل جهازك بموقع يسأل عن اسمه (مثل example.com). يفحص SafeGuard هذا الاسم عبر اتصال VPN محلي، ويحجب ما ينتمي للفئات التي تختارها.',
        'Before your device connects to a site, it looks up its name (like example.com). SafeGuard checks that name through a local VPN and blocks what belongs to the categories you choose.',
      ),
      [
        tr(
          'يرى أسماء النطاقات فقط، لا محتوى الصفحات',
          'Sees domain names only, not page content',
        ),
        tr(
          'الاتصال لا يغادر جهازك إلى أي خادم لنا',
          'The connection never goes to any server of ours',
        ),
      ],
    ),
    _Page(
      Icons.manage_search_rounded,
      tr('حماية البحث', 'Search protection'),
      tr(
        'يفرض البحث الآمن في Google وBing والوضع المقيّد في YouTube، ويفحص ما تبحث عنه عبر شاشة البحث في SafeGuard.',
        'Enforces SafeSearch on Google and Bing and Restricted Mode on YouTube, and checks what you search for in SafeGuard\'s own search screen.',
      ),
      [
        tr(
          'لا يقرأ ما تكتبه في التطبيقات الأخرى، إلا مربع البحث في التطبيقات التي تختار حمايتها بدرع المحتوى',
          'It doesn\'t read what you type in other apps, except the search box in apps you protect with the Content Shield',
        ),
      ],
    ),
    _Page(
      Icons.auto_awesome_outlined,
      tr('الكشف الذكي', 'AI content detection'),
      tr(
        'نموذج صغير يعمل على جهازك يصنّف نص البحث عند الطلب. لا يُرفع شيء، ولا يُحظر ما هو غير مؤكد في الوضع العادي.',
        'A small model on your device classifies search text on demand. Nothing is uploaded, and uncertain results aren\'t blocked in Normal mode.',
      ),
      [
        tr(
          'دقته محدودة: قد يخطئ أو يفوته شيء',
          'Its accuracy is limited: it can be wrong or miss things',
        ),
      ],
    ),
    _Page(
      Icons.verified_user_outlined,
      tr('الأذونات المطلوبة', 'Permissions needed'),
      tr(
        'يطلب SafeGuard فقط ما تحتاجه كل ميزة، ويشرح السبب قبل الطلب.',
        'SafeGuard asks only for what each feature needs, and explains why first.',
      ),
      [
        tr(
          'موافقة VPN: لفلترة DNS (مطلوبة)',
          'VPN consent: for DNS filtering (required)',
        ),
        tr(
          'تسهيل الاستخدام: لحماية التطبيقات فقط (اختيارية)',
          'Accessibility: for app protection only (optional)',
        ),
        tr(
          'لا جذر (root)، لا جهات اتصال، لا موقع، لا كاميرا',
          'No root, contacts, location or camera',
        ),
      ],
    ),
    _Page(
      Icons.phone_android_rounded,
      tr('بياناتك تبقى هنا', 'Your data stays here'),
      tr(
        'الإعدادات والقوائم والسجل محفوظة على هذا الجهاز فقط. لا تحليلات ولا تتبع. رمز PIN مشفّر ولا يُحفظ كنص.',
        'Settings, lists and the log are stored on this device only. No analytics, no tracking. Your PIN is encrypted and never stored as text.',
      ),
    ),
    _Page(
      Icons.info_outline_rounded,
      tr('حدود يجب أن تعرفها', 'Limits you should know'),
      tr(
        'SafeGuard لا يستطيع التحكم بكل شيء في Android، ولا يضمن حجب كل المحتوى.',
        'SafeGuard can\'t control everything on Android, and doesn\'t guarantee blocking all content.',
      ),
      [
        tr(
          'التطبيقات والمتصفحات التي تستخدم DNS مشفّرًا خاصًا بها قد تتجاوز الفلترة',
          'Apps and browsers that use their own encrypted DNS may bypass filtering',
        ),
        tr(
          'لا يمكن فلترة المنشورات داخل إنستغرام وتيك توك',
          'Posts inside Instagram and TikTok can\'t be filtered',
        ),
        tr('يعمل VPN واحد فقط في الوقت نفسه', 'Only one VPN can run at a time'),
      ],
    ),
    _Page(
      Icons.power_settings_new_rounded,
      tr('تفعيل الحماية', 'Turning protection on'),
      tr(
        'أنشئ رمز PIN (يحمي الإعدادات من التعطيل)، ثم يرشدك معالج قصير لاختيار الوضع والفئات ومنح الأذونات، ويتحقق من أن الحماية تعمل فعلًا.',
        'Create a PIN (it protects the settings from being turned off), then a short wizard helps you choose a mode and categories, grant permissions, and checks that protection actually works.',
      ),
    ),
  ];

  bool get _last => _index == _pages.length - 1;

  void _go(int i) => _controller.animateToPage(
    i,
    duration: SgMotion.medium,
    curve: SgMotion.standard,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pages = _pages;
    final language = AppScope.of(context).settings.settings.language;
    return Scaffold(
      body: SafeArea(
        child: SgContentWidth(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: SgSpace.x3),
                child: Row(
                  children: [
                    const ShieldMark(size: 28),
                    const Spacer(),
                    // Icon only: the language name is in the tooltip and
                    // semantics, so the row fits 320 px at large text.
                    IconButton(
                      tooltip: tr(
                        'اللغة: ${languageLabel(language)}',
                        'Language: ${languageLabel(language)}',
                      ),
                      onPressed: () => pickLanguage(context),
                      icon: const Icon(Icons.translate_rounded),
                    ),
                    if (!_last)
                      SgTextButton(
                        label: tr('تخطي', 'Skip'),
                        onPressed: () => _go(pages.length - 1),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: pages.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => _PageView(page: pages[i]),
                ),
              ),
              Semantics(
                label: tr(
                  'الصفحة ${_index + 1} من ${pages.length}',
                  'Page ${_index + 1} of ${pages.length}',
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < pages.length; i++)
                      AnimatedContainer(
                        duration: SgMotion.medium,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: i == _index ? 18 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i == _index ? c.accent : c.borderStrong,
                          borderRadius: SgRadius.pillAll,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: SgSpace.x4),
                child: _last
                    ? PrimaryButton(
                        label: tr('إعداد رمز PIN', 'Set up a PIN'),
                        onPressed: () => context.push(Routes.createPin),
                      )
                    : PrimaryButton(
                        label: tr('التالي', 'Next'),
                        onPressed: () => _go(_index + 1),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageView extends StatelessWidget {
  const _PageView({required this.page});
  final _Page page;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: SgSpace.x8, bottom: SgSpace.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SgIconWell(
            icon: page.icon,
            foreground: c.accent,
            background: c.accentMuted,
          ),
          const SizedBox(height: SgSpace.x6),
          Text(page.title, style: context.text.headlineSmall),
          const SizedBox(height: SgSpace.x3),
          Text(
            page.body,
            style: context.text.bodyLarge!.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: SgSpace.x4),
          for (final p in page.points)
            Padding(
              padding: const EdgeInsets.only(bottom: SgSpace.x2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: StatusDot(color: c.accent, size: 6),
                  ),
                  const SizedBox(width: SgSpace.x3),
                  Expanded(child: Text(p, style: context.text.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
