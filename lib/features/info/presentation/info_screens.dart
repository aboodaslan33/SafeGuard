import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_dependencies.dart';
import '../../../app/app_info.dart';
import '../../../app/router/routes.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/i18n/i18n.dart';
import '../../advanced/presentation/advanced_actions.dart';

/// Question → answer row that expands in place.
class _Faq extends StatelessWidget {
  const _Faq(this.question, this.answer);
  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: SgSpace.x4),
        childrenPadding: const EdgeInsets.fromLTRB(
          SgSpace.x4,
          0,
          SgSpace.x4,
          SgSpace.x4,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(question, style: context.text.titleSmall),
        children: [Text(answer, style: context.text.bodyMedium)],
      ),
    );
  }
}

/// Help: the questions beta testers actually ask, with honest answers.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SgPage(
      showBack: true,
      title: tr('المساعدة', 'Help'),
      subtitle: tr(
        'حلول للمشكلات الشائعة وحدود الحماية.',
        'Fixes for common problems, and the limits of protection.',
      ),
      children: [
        SectionHeader(title: tr('حل المشكلات', 'Troubleshooting')),
        SgGroupedCard(
          children: [
            _Faq(
              tr(
                'انقطع الإنترنت بعد تشغيل الحماية',
                'The internet stopped after turning on protection',
              ),
              tr(
                'استخدم «وضع الأمان» من الإعدادات: يوقف اتصال VPN الخاص بـ SafeGuard فورًا ويعيد الإنترنت. '
                    'ثم افتح «التشخيص» وانسخ المعلومات لإرسالها للدعم.',
                'Use Safe Mode in Settings: it stops SafeGuard\'s VPN at once and restores the internet. '
                    'Then open Diagnostics and copy the information to send to support.',
              ),
            ),
            _Faq(
              tr('موقع أحتاجه محظور', 'A site I need is blocked'),
              tr(
                'أضفه إلى «النطاقات المسموحة» (يتطلب PIN). القوائم تُجمع آليًا وقد تخطئ أحيانًا.',
                'Add it to Allowed domains (requires the PIN). The lists are compiled automatically and are sometimes wrong.',
              ),
            ),
            _Faq(
              tr(
                'ما زال محتوى يظهر في المتصفح',
                'Some content still appears in the browser',
              ),
              tr(
                'تحقق من: «DNS الآمن» في Chrome، و«DNS الخاص» في Android (اضبطه على تلقائي)، وأن الحماية تعمل في «مساعد الإعداد». '
                    'الحجب يتم على مستوى أسماء النطاقات؛ الصفحات داخل موقع مسموح لا تُفحص.',
                'Check Chrome\'s “Secure DNS”, Android\'s Private DNS (set it to Automatic), and that protection runs in the Setup assistant. '
                    'Blocking works on domain names; pages inside an allowed site aren\'t inspected.',
              ),
            ),
            _Faq(
              tr(
                'توقفت الحماية بعد إعادة تشغيل الجهاز',
                'Protection stopped after restarting the device',
              ),
              tr(
                'فعّل «VPN دائم التشغيل» لـ SafeGuard في إعدادات VPN، واستثنِ SafeGuard من تحسين البطارية. التفاصيل في «مساعد الإعداد».',
                'Turn on Always-on VPN for SafeGuard in VPN settings, and exempt SafeGuard from battery optimisation. Details in the Setup assistant.',
              ),
            ),
            _Faq(
              tr('أستخدم تطبيق VPN آخر', 'I use another VPN app'),
              tr(
                'Android يشغّل VPN واحدًا فقط. عند تشغيل الآخر يتوقف SafeGuard ويعرض ذلك بوضوح، ولا يحاول إيقاف التطبيق الآخر.',
                'Android runs only one VPN. When the other one starts, SafeGuard stops and says so clearly — it never tries to stop the other app.',
              ),
            ),
            _Faq(
              tr('نسيت رمز PIN', 'I forgot my PIN'),
              tr(
                'لا يمكن استعادته من داخل التطبيق حتى لا تُعطَّل الحماية بسهولة. امسح بيانات SafeGuard من إعدادات Android ← التطبيقات؛ سيبدأ من جديد.',
                "It can't be recovered inside the app, so protection can't be disabled easily. Clear SafeGuard's data in Android settings → Apps; it starts over.",
              ),
            ),
          ],
        ),
        SectionHeader(title: tr('كيف يعمل', 'How it works')),
        SgGroupedCard(
          children: [
            _Faq(
              tr('ماذا يرى SafeGuard؟', 'What does SafeGuard see?'),
              tr(
                'أسماء النطاقات في طلبات DNS فقط (مثل example.com)، وما تبحث عنه عبر شاشة البحث في SafeGuard. '
                    'لا يرى محتوى الصفحات أو الرسائل أو كلمات المرور أو الصور.',
                'Only domain names in DNS requests (like example.com), and what you search for in SafeGuard\'s own search screen. '
                    'It doesn\'t see page content, messages, passwords or photos.',
              ),
            ),
            _Faq(
              tr(
                'ماذا عن إنستغرام وتيك توك؟',
                'What about Instagram and TikTok?',
              ),
              tr(
                'لا يستطيع أي تطبيق فلترة المنشورات داخلها. استخدم إعداد «المحتوى الحساس ← أقل» في إنستغرام، أو احمِ التطبيق كاملًا.',
                'No app can filter posts inside them. Use Instagram\'s “Sensitive content → Less” setting, or protect the whole app.',
              ),
            ),
            _Faq(
              tr('هل الحماية كاملة؟', 'Is protection complete?'),
              tr(
                'لا. SafeGuard يضيف طبقات حماية لكنه لا يضمن حجب كل شيء. DNS المشفّر داخل التطبيقات، وVPN آخر، وتغيير إعدادات Android قد تتجاوزه.',
                'No. SafeGuard adds layers of protection but doesn\'t guarantee blocking everything. Encrypted DNS inside apps, another VPN, or changes to Android settings can get around it.',
              ),
            ),
          ],
        ),
        SectionHeader(title: tr('الدعم', 'Support')),
        SgGroupedCard(
          children: [
            SecuritySettingTile(
              icon: Icons.thumb_down_alt_outlined,
              title: tr('الإبلاغ عن حظر خاطئ', 'Report a false positive'),
              onTap: () => context.push(Routes.feedbackFor('false_positive')),
            ),
            SecuritySettingTile(
              icon: Icons.visibility_outlined,
              title: tr('الإبلاغ عن محتوى لم يُحجب', 'Report missed content'),
              onTap: () => context.push(Routes.feedbackFor('missed_content')),
            ),
            SecuritySettingTile(
              icon: Icons.build_outlined,
              title: tr('الإبلاغ عن مشكلة تقنية', 'Report a technical problem'),
              onTap: () =>
                  context.push(Routes.feedbackFor('technical_problem')),
            ),
            SecuritySettingTile(
              icon: Icons.fact_check_outlined,
              title: tr('مساعد الإعداد', 'Setup assistant'),
              onTap: () => context.push(Routes.setupAssistant),
            ),
            SecuritySettingTile(
              icon: Icons.bug_report_outlined,
              title: tr('التشخيص', 'Diagnostics'),
              subtitle: tr(
                'انسخ معلومات تقنية دون بيانات شخصية لإرسالها للدعم',
                'Copy technical information without personal data to send to support',
              ),
              onTap: () => context.push(Routes.diagnostics),
            ),
          ],
        ),
      ],
    );
  }
}

/// About: identity, build, attributions, and an honest scope statement.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SgPage(
      showBack: true,
      title: tr('حول SafeGuard', 'About SafeGuard'),
      children: [
        SgCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: SafeGuardWordmark(),
              ),
              const SizedBox(height: SgSpace.x3),
              Text(
                tr(
                  'حماية محتوى محلية لأجهزة Android: فلترة DNS، حماية البحث، حماية التطبيقات، وتصنيف ذكي على الجهاز.',
                  'Local content protection for Android: DNS filtering, search protection, app protection, and on-device AI classification.',
                ),
                style: context.text.bodyMedium,
              ),
              const SizedBox(height: SgSpace.x3),
              Text(
                AppInfo.full,
                textDirection: TextDirection.ltr,
                style: context.text.labelMedium!.copyWith(
                  color: c.textTertiary,
                ),
              ),
            ],
          ),
        ),
        SectionHeader(title: tr('المصادر والتراخيص', 'Sources and licences')),
        SgGroupedCard(
          children: [
            SecuritySettingTile(
              icon: Icons.list_alt_rounded,
              title: tr('قوائم النطاقات', 'Domain lists'),
              subtitle: tr(
                'The Block List Project (Unlicense / MIT): مقامرة، محتوى جنسي، مخدرات',
                'The Block List Project (Unlicense / MIT): gambling, sexual content, drugs',
              ),
              showChevron: false,
            ),
            SecuritySettingTile(
              icon: Icons.psychology_outlined,
              title: tr('نموذج النص', 'Text model'),
              subtitle: tr(
                'نموذج صغير مدرَّب ضمن المشروع، يعمل على الجهاز فقط',
                'A small model trained within the project, runs on the device only',
              ),
              showChevron: false,
            ),
            SecuritySettingTile(
              icon: Icons.description_outlined,
              title: tr(
                'تراخيص البرمجيات مفتوحة المصدر',
                'Open-source licences',
              ),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'SafeGuard',
                applicationVersion: AppInfo.version,
              ),
            ),
          ],
        ),
        const SizedBox(height: SgSpace.x4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
          child: Text(
            tr(
              'لا حساب، لا خوادم، لا إعلانات، لا أدوات تتبع. SafeGuard طبقات حماية متعددة ولا يضمن حجب 100% من المحتوى.',
              'No account, no servers, no ads, no trackers. SafeGuard is a multi-layer protection system and doesn\'t guarantee blocking 100% of content.',
            ),
            style: context.text.bodySmall!.copyWith(color: c.textTertiary),
          ),
        ),
      ],
    );
  }
}

/// Privacy: exactly what is stored, where, for how long — and the controls.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).protection.engine;
    Widget point(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SgSpace.x4,
        vertical: SgSpace.x3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SgIconWell(icon: icon),
          const SizedBox(width: SgSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                const SizedBox(height: SgSpace.x1),
                Text(body, style: context.text.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );

    return SgPage(
      showBack: true,
      title: tr('الخصوصية', 'Privacy'),
      subtitle: tr(
        'كل شيء يبقى على هذا الجهاز.',
        'Everything stays on this device.',
      ),
      children: [
        SectionHeader(title: tr('ما يُحفظ', 'What is stored')),
        SgGroupedCard(
          children: [
            point(
              Icons.history_rounded,
              tr('سجل الحماية', 'Protection log'),
              tr(
                'الوقت والفئة والمصدر، والنطاق المحجوب أو اسم التطبيق المحمي. للبحث: رقم مختصر غير قابل للعكس بدل النص. '
                    'يُحذف تلقائيًا حسب «مدة الاحتفاظ بالسجل».',
                'Time, category and source, plus the blocked domain or protected app name. For searches: a short non-reversible number instead of the text. '
                    'Deleted automatically according to Log retention.',
              ),
            ),
            point(
              Icons.tune_rounded,
              tr('إعداداتك وقوائمك', 'Your settings and lists'),
              tr(
                'الوضع والفئات والقوائم والكلمات والتطبيقات المحمية، في مساحة التطبيق الخاصة. مستثناة من النسخ الاحتياطي السحابي.',
                'Mode, categories, lists, keywords and protected apps, in the app\'s private storage. Excluded from cloud backup.',
              ),
            ),
            point(
              Icons.pin_outlined,
              tr('رمز PIN', 'PIN'),
              tr(
                'لا يُحفظ الرمز نفسه، بل تجزئة PBKDF2 مع ملح، مشفّرة بمفتاح Android Keystore.',
                'The PIN itself isn\'t stored — only a salted PBKDF2 hash, encrypted with an Android Keystore key.',
              ),
            ),
          ],
        ),
        SectionHeader(title: tr('ما لا يُجمع أبدًا', 'Never collected')),
        SgCard(
          child: Text(
            tr(
              'كلمات المرور، الرسائل، الصور، جهات الاتصال، سجل التصفح الكامل، نصوص البحث، تسجيلات الشاشة أو الصوت. '
                  'لا تحليلات ولا تقارير أعطال تُرسل. الصور التي تفحصها تُعالج في الذاكرة ولا تُحفظ.',
              'Passwords, messages, photos, contacts, full browsing history, search text, screen or audio recordings. '
                  'No analytics or crash reports are sent. Images you check are processed in memory and not saved.',
            ),
            style: context.text.bodyMedium,
          ),
        ),
        SectionHeader(title: tr('عناصر التحكم', 'Controls')),
        SgGroupedCard(
          children: [
            if (engine.isSupported)
              SecuritySettingTile(
                icon: Icons.cleaning_services_outlined,
                title: tr('مسح سجل الحماية', 'Clear protection log'),
                onTap: () => AdvancedActions.clearLogs(context),
              ),
            if (engine.isSupported)
              SecuritySettingTile(
                icon: Icons.ios_share_rounded,
                title: tr('تصدير الإعدادات', 'Export settings'),
                onTap: () => AdvancedActions.exportSettings(context),
              ),
            SecuritySettingTile(
              icon: Icons.insights_outlined,
              title: tr('التحليلات والتقارير', 'Analytics and reports'),
              onTap: () => context.push(Routes.analytics),
            ),
            SecuritySettingTile(
              icon: Icons.settings_rounded,
              title: tr(
                'مدة السجل وحذف كل البيانات',
                'Log retention and deleting all data',
              ),
              subtitle: tr('في الإعدادات ← الخصوصية', 'In Settings → Privacy'),
              onTap: () => context.go(Routes.settings),
            ),
          ],
        ),
      ],
    );
  }
}
