# SafeGuard

**حماية المحتوى على مستوى جهاز Android. عربي أولًا، خاص، وصريح بشأن حدوده.**

SafeGuard تطبيق Flutter + Kotlin يهدف إلى حجب المحتوى غير المرغوب فيه
(جنسي، عنف، محتوى دموي، مقامرة، مخدرات، محتوى خطِر، بحث غير آمن) على
مستوى الشبكة في الجهاز، دون حسابات أو خوادم.

> **الحالة: المرحلة الثانية (Phase 2).** يعمل الآن VPN محلي حقيقي على
> Android يعترض طلبات DNS فقط، ويقرر لكل نطاق ALLOW أو BLOCK عبر محرك
> قواعد محلي (SQLite)، مع قائمة حظر وقائمة سماح مخصصتين، وسجل حظر
> وإحصاءات محلية. **لا يوجد أي خادم:** الطلبات المسموحة تذهب إلى خادم DNS
> الخاص بشبكتك كما لو لم يكن SafeGuard موجودًا.
>
> ⚠️ **لم يُختبر على جهاز حقيقي بعد.** بيئة التطوير لم تكن تملك Android SDK
> (المصدر محجوب بسياسة الشبكة). المنطق الأصلي مختبر بـ JUnit، وطبقة
> Android مُتحقق من ترجمتها أمام إطار API 36، لكن خطة الاختبار اليدوي في
> [`docs/MANUAL_TESTING.md`](docs/MANUAL_TESTING.md) لم تُنفذ بعد.
>
> ⚠️ **لا توجد قوائم فئات مضمّنة في نسخة الإصدار.** لم ننسخ قوائم مواقع
> البالغين أو المقامرة في الكود المصدري. نسخة الإصدار تحظر ما تضيفه أنت
> فقط، إلى أن تُضاف قوائم موثوقة عبر `RemoteRuleSource` (المرحلة 3).
> نسخة debug تحتوي نطاقات اختبار (`example.org` = جنسي، `example.net` =
> مقامرة). التطبيق يعرض هذا للمستخدم بوضوح.

---

## ما يستطيعه Android وما لا يستطيعه

| الوظيفة | الحالة | الطريقة / الحد |
|---|---|---|
| حجب نطاقات لكل التطبيقات | ✅ منفّذ | `VpnService` محلي يوجّه عنوان DNS افتراضيًا واحدًا فقط إلى الـtun؛ باقي الحركة لا تمر عبره |
| النطاقات الفرعية | ✅ | مطابقة على مستوى الـlabels: `example.com` يطابق `www.example.com` ولا يطابق `safe-example.com` |
| العمل دون إنترنت | ✅ | القواعد محلية؛ الحظر مستمر، والطلبات المسموحة ترجع `SERVFAIL` فورًا |
| فرض البحث الآمن | ❌ ليس بعد | `SearchFilterService` واجهة فقط (المرحلة 3) |
| DNS over HTTPS داخل المتصفح (Chrome «Secure DNS»، Firefox DoH) | ⚠️ يتجاوز الفلترة | المتصفح لا يستخدم DNS النظام. لا نحاول كسره |
| DNS over TLS / «DNS الخاص» في Android بمزوّد محدد | ⚠️ يتجاوز الفلترة | نكتشفه ونعرض تحذيرًا واضحًا |
| تطبيقات بخوادم DNS مثبتة في الكود (مثل `8.8.8.8`) | ⚠️ تتجاوز الفلترة | لا نوجّه عناوين أخرى عبر الـVPN، عمدًا (خصوصية وأداء) |
| VPN آخر | ⚠️ | يعمل VPN واحد فقط على Android؛ نكتشف ذلك ونعرض: «يوجد VPN آخر نشط وقد يمنع SafeGuard من العمل.» ولا نحاول تعطيله |
| DNS عبر TCP أو IPv6 إلى العنوان الافتراضي | ⚠️ | غير مدعوم؛ نادر عمليًا. الردود الأكبر من الـMTU تُقتطع مع علامة TC |
| قراءة محتوى الصور/المنشورات داخل تطبيقات أخرى | ❌ | Android يعزل التطبيقات. لا نستخدم Accessibility Service |
| منع إزالة التطبيق أو فصل VPN | ❌ | يتطلب Device Owner. المستخدم يتحكم دائمًا من إعدادات النظام |
| البقاء في الخلفية | ⚠️ | النظام يُبقي خدمة VPN المتصلة حية دون Foreground Service، لكن بعض الشركات المصنّعة (إدارة بطارية عدوانية) قد توقفها؛ يظهر ذلك فورًا كـ«غير نشطة» |
| العودة بعد إعادة التشغيل | ⚠️ | BootReceiver محاولة أفضل-جهد؛ الطريقة الموثوقة هي «VPN دائم التشغيل» في إعدادات Android |

هذه الحدود معروضة للمستخدم في شاشة **الحالة ← حدود الحماية**.


## البنية المعمارية

التفاصيل الكاملة (المسار من Flutter إلى الحزمة، أولوية القواعد، دورة حياة
الـVPN، نقاط التوسعة): [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

```
Flutter UI → ProtectionController → ProtectionEngine (Dart port)
  → MethodChannel/EventChannel → ProtectionChannel.kt → ProtectionManager.kt
  → SafeGuardVpnService (tun, Os.poll) → DnsPacketFilter → RuleEngine → SQLite
  → BLOCK: NXDOMAIN + سجل محلي   |   ALLOW: DnsForwarder → DNS الشبكة نفسها
```

**Kotlin** (`android/app/src/main/kotlin/com/safeguard/app/`):

```
engine/            ← Kotlin خالص بلا android.* (مختبر على JVM)
  domain/          DomainName: تطبيع، تحقق، IDN، مرشحات اللاحقة
  dns/             Ipv4Udp, DnsMessage, DnsPacketFilter
  rules/           Rule, RuleStore, RuleEngine (+LRU), BuiltInRules, HostsListParser
  logging/ stats/  BlockLogger (async + dedupe), StatisticsService
  status/          ProtectionStatus + انتقالات الحالة
  search/          SearchFilterService (placeholder)
  extensions/      واجهات مستقبلية فقط
data/              SQLite: SafeGuardDatabase, SqliteRuleStore, SqliteBlockEventStore
protection/        ProtectionManager (facade), ProtectionConfigStore
vpn/               SafeGuardVpnService, DnsForwarder, NetworkMonitor, BootReceiver
channel/           ProtectionChannel (API المنصة)
```

**Flutter** (`lib/`): Clean Architecture خفيفة، مقسّمة حسب الميزة (feature-first). كل ميزة فيها
`domain` (نماذج وقواعد وواجهات) و`data` (تطبيقات التخزين) و`presentation`
(Controllers + Widgets).

```
lib/
├── main.dart                     # نقطة الدخول: معالجات الأخطاء + runApp
├── app/
│   ├── app_dependencies.dart     # Composition root + AppScope (DI بلا مكتبات)
│   ├── safeguard_app.dart        # MaterialApp.router، الثيم، RTL، القفل عند الخلفية
│   └── router/
│       ├── routes.dart           # المسارات + سياسة التوجيه (دالة نقية، مختبرة)
│       ├── app_router.dart       # GoRouter + بوابة PIN (requirePin)
│       └── app_shell.dart        # شريط التنقل السفلي
├── core/
│   ├── design_system/            # Tokens + Theme + Components (انظر أدناه)
│   ├── error/                    # AppFailure (sealed)، Result<T>، guard()، ErrorBoundary
│   ├── storage/                  # KeyValueStore / SecureStore + تطبيقاتها
│   ├── security/pbkdf2.dart      # PBKDF2-HMAC-SHA256 + مقارنة زمن ثابت
│   ├── platform/secure_screen.dart     # FLAG_SECURE ← MainActivity.kt
│   ├── platform/protection_channel.dart # قناة الحماية (typed) ← ProtectionChannel.kt
│   └── utils/
└── features/
    ├── protection/   # ProtectionState، EngineSnapshot، ProtectionEngine + NativeProtectionEngine
    ├── rules/        # قائمة الحظر وقائمة السماح + تحقق النطاق
    ├── activity/     # سجل الحظر
    ├── pin/          # PinPolicy، PinService، التجزئة، شاشات الإعداد/القفل/التحقق
    ├── settings/     # AppSettings + المستودع + الشاشة
    ├── home/  status/  onboarding/  splash/  blocking/
```

**قرارات رئيسية**

- **إدارة الحالة:** `ChangeNotifier` + `ListenableBuilder` + `InheritedWidget`.
  لا حاجة لمكتبة إضافية في هذا الحجم؛ الواجهات مجرّدة بحيث يمكن الانتقال
  إلى Riverpod لاحقًا دون تغيير الـdomain.
- **التوجيه:** `go_router` مع `redirect` واحد مركزي. السياسة
  (`resolveRedirect`) دالة نقية مختبرة: تحميل ← إعداد أول ← قفل ← التطبيق.
  الموجّه لا يُحدَّث إلا عند تغيّر حالة البوابة فعليًا (`_GateNotifier`).
- **الأخطاء:** كل عملية قابلة للفشل تعيد `Result<T>` (`Ok`/`Err`) مع
  `AppFailure` مُصنّف (`StorageFailure`, `PinMismatchFailure`,
  `PinLockedFailure`, `ValidationFailure`, `CorruptedDataFailure`,
  `UnexpectedFailure`). الأخطاء غير الملتقطة تمر عبر `ErrorBoundary`
  (سجل محلي فقط، لا إرسال لأي جهة).
- **الفشل الآمن (fail closed):** بيانات حماية تالفة ← حماية كاملة، لا صفر.
  عدّاد محاولات تالف ← يقترب من الإقفال، لا يُصفَّر.
- **المحرك خلف منفذ (port):** `ProtectionEngine` واجهة في الـdomain؛
  على Android تُنفَّذ بـ `NativeProtectionEngine`، وفي الاختبارات بمحرك وهمي
  له العقد نفسه. الحالة الحية تأتي من الجانب الأصلي عبر EventChannel، ولا
  تُعرض «الحماية نشطة» إلا إذا كان VPN يعمل وفلتر DNS نشطًا والقواعد محمّلة.
- **مصدر الحقيقة للإعدادات:** Flutter، مع نسخة أصلية
  (`ProtectionConfigStore`) تُحدَّث عند كل تغيير لأن الـVPN يجب أن يعمل
  دون Flutter (بعد إعادة التشغيل مثلًا).

---

## الأمان

**رمز PIN (4 أو 6 أرقام، الافتراضي 6)**

- لا يُخزَّن الرمز كنص أبدًا. يُخزَّن: `PBKDF2-HMAC-SHA256`، 120,000 تكرار،
  ملح عشوائي 16 بايت لكل رمز (`Random.secure`)، مخرجات 32 بايت.
- التحقق بمقارنة زمن ثابت. التجزئة تعمل في Isolate منفصل.
- السجل محفوظ في `flutter_secure_storage` (مفتاح AES-GCM مرتبط بـ Android
  Keystore).
- رفض الرموز السهلة (`0000`, `1234`, `987654`...).
- **إبطاء التخمين:** 5 محاولات خاطئة ثم إقفال متصاعد
  (30ث ← 1د ← 5د ← 15د ← 1س). العدّاد محفوظ ويبقى بعد إعادة التشغيل.
- `FLAG_SECURE` على شاشات PIN (عبر Platform Channel) لمنع لقطات الشاشة
  والتسجيل وصورة التطبيقات الأخيرة.

**تقييم صريح:** مساحة رمز من 6 أرقام هي 10⁶ فقط، ولذلك لا تحمي أي دالة
تجزئة من هجوم offline على سجل مسروق. الحماية الحقيقية هي: التخزين المشفّر
بـKeystore + الإبطاء + عدم وجود نسخ احتياطي.
الإقفال المؤقت يعتمد على ساعة الجهاز؛ تغييرها يدويًا قد يختصره (سيُعالج
لاحقًا بـ `elapsedRealtime` من الجانب الأصلي).

**ما يتطلب رمز PIN:** إيقاف الحماية، تعطيل أي فئة، فتح قائمة السماح
(كل إدخال فيها يخفف الحماية)، إزالة نطاق من قائمة الحظر، مسح سجل الحظر،
إيقاف قفل التطبيق، تغيير الرمز، حذف البيانات. **التشديد (التفعيل، إضافة
نطاق محظور) لا يتطلبه أبدًا.**

**الشبكة والخصوصية (المرحلة 2)**

- VPN محلي فقط. لا خادم لـ SafeGuard. لا رفع للحزم، ولا جمع لحركة المرور.
- الـVPN لا يرى إلا طلبات DNS الموجّهة إلى العنوان الافتراضي؛ كل الحركة
  الأخرى لا تدخل الـtun أصلًا.
- الطلب المسموح يُرسل إلى خادم DNS الخاص بالشبكة الحالية (الخادم نفسه الذي
  كان سيُستخدم دون SafeGuard). **استثناء واحد:** إن لم تُعلن الشبكة أي خادم
  DNS (نادر)، يُستخدم `1.1.1.1` ثم `9.9.9.9`.
- السجل: الوقت + النطاق + الفئة فقط، محليًا، 30 يومًا كحد أقصى (10,000
  حدث)، ويمكن مسحه.
- التحقق من المدخلات في الطرفين: تطبيع النطاق، رفض المشوّه وعناوين IP،
  حدود الطول، IDN إلى punycode. كل استعلامات SQLite بمعاملات مربوطة، و
  حرفية `LIKE` مهرّبة. الحد الأقصى 2,000 قاعدة مخصصة.
- محلل حزم DNS دفاعي: حدود لكل قراءة، حد لقفزات الضغط، رفض المؤشرات
  الدائرية، واختبار fuzzing بـ 40,000 مدخل عشوائي.
- قائمة انتظار الإرسال محدودة (256) مع إسقاط الأقدم عند الفيضان، بدل نمو
  الذاكرة بلا حد.

**Android**

- `allowBackup="false"` + `dataExtractionRules` تستثني كل شيء (مفاتيح
  Keystore لا تنتقل بين الأجهزة أصلًا).
- الصلاحيات: `INTERNET` (تمرير DNS المسموح إلى خادم الشبكة)،
  `ACCESS_NETWORK_STATE` (تتبع تبدّل الشبكة وخوادم DNS)،
  `RECEIVE_BOOT_COMPLETED` (محاولة التشغيل بعد الإقلاع). لا صلاحية
  Accessibility، ولا موقع، ولا إشعارات، ولا Foreground Service.
- موافقة VPN تأتي فقط من نافذة النظام الرسمية (`VpnService.prepare`)،
  وتسبقها شاشة شرح بالنص المطلوب. لا تجاوز ولا إخفاء.
- `usesCleartextTraffic="false"`، `minSdk 24`.
- القفل التلقائي بعد 30 ثانية في الخلفية.

---

## نظام التصميم

الشخصية: **هادئ، موثوق، خاص، احترافي.** لا نيون، لا طابع "هاكر"، ولا
رسومات طفولية.

| الطبقة | الملف | المحتوى |
|---|---|---|
| الألوان | `tokens/sg_colors.dart` | ألوان دلالية (`accent`, `warning`, `danger`, `info` + نسخ `Muted`) لثيم داكن وفاتح. لون العلامة = لون "محمي" عمدًا |
| الخط | `tokens/sg_typography.dart` | IBM Plex Sans Arabic (مرفق، رخصة OFL)، ارتفاع أسطر 1.45–1.65 مناسب للعربية، أوزان ≤ 600 للعناوين |
| المسافات والزوايا والظل والحركة | `tokens/sg_tokens.dart` | شبكة 4pt، هامش 20، أقصى عرض 560، زوايا 8/12/16/24، ظل في الفاتح فقط، حركة 150–400ms بلا ارتداد |
| الثيم | `theme/app_theme.dart` | يربط الـtokens بـ Material 3 (Switch، NavigationBar، Dialog، BottomSheet، SnackBar، Input) |
| المكونات | `components/` | `PrimaryButton` `SecondaryButton` `SgTextButton` `SgCard` `SgGroupedCard` `SecuritySettingTile` `StatusIndicator` `SectionHeader` `PinKeypad` `PinDots` `EmptyState` `ErrorState` `LoadingState` `showSgConfirmDialog` `showSgBottomSheet` `ShieldMark` `SgPage` |
| مكونات الميزة | `features/protection/presentation/protection_ui.dart` | `ProtectionStatusCard` (نشطة / غير نشطة / متوقفة + شبكة الطبقات) `EngineWarnings` `CategoryTile` |

**قرارات UX**

- **الرئيسية تجيب على سؤال واحد:** "هل أنا محمي، ومن ماذا؟". بطاقة الحالة ثم
  الفئات. الإحصاءات والطبقات في تبويب "الحالة".
- **إيقاف الحماية هو الزر الأهدأ** (outlined)، والتفعيل هو الزر البارز.
- **Onboarding شاشة واحدة** (لا carousel): ما يفعله التطبيق، كيف يعامل
  البيانات، وحدوده، ثم إعداد PIN مباشرة.
- **لوحة الأرقام LTR دائمًا** (1-2-3 من اليسار) حتى في RTL، كما في كل
  تطبيقات البنوك والاتصال العربية.
- **لا أرقام وهمية:** الإحصاءات تُعرض "—" مع شرح حين لا يوجد محرك.
- **ثلاث حالات واضحة للحماية:** نشطة (أخضر)، غير نشطة رغم رغبة المستخدم
  (أحمر + سبب محدد + زر «تشغيل الحماية»)، متوقفة بقرار المستخدم (كهرماني).
- **التحذيرات تظهر فقط عند وجودها:** VPN آخر، «DNS الخاص»، لا قوائم فئات،
  لا اتصال.
- **الحالة لا تعتمد على اللون وحده:** كل مؤشر يحمل نصًا.
- **شاشة الحظر محايدة:** لا لوم، لا عرض للرابط المحجوب، زر واحد "العودة".

---

## التشغيل

**المتطلبات:** Flutter 3.47+ (Dart 3.13+)، Android SDK 36، JDK 17+.

```bash
flutter pub get
flutter run                 # على جهاز أو محاكي Android
flutter analyze             # يجب أن يكون نظيفًا
flutter test                # كل الاختبارات
flutter build apk --release # يوقَّع بمفتاح debug مؤقتًا (انظر أدناه)
```

**قبل النشر على Google Play:**

1. غيّر `applicationId` في `android/app/build.gradle.kts` (حاليًا
   `com.safeguard.app` كقيمة مؤقتة).
2. أنشئ keystore للإصدار وأضف `signingConfigs.release`. ملفات المفاتيح
   مستثناة في `.gitignore`. **لا توجد أسرار في المستودع.**

---

## الاختبارات

**Flutter — 73 اختبارًا** (`flutter test`)

| الملف | ما يغطيه |
|---|---|
| `test/core/pbkdf2_test.dart` | متجهات RFC 7914 §11 الرسمية، المقارنة الثابتة، تفرّد الملح |
| `test/features/pin_test.dart` | قواعد الرمز، الإقفال والتصاعد، تغيير الرمز، البيانات التالفة |
| `test/features/protection_settings_test.dart` | حالة الحماية، الحفظ والتراجع، مزامنة المحرك، الإعدادات |
| `test/features/engine_integration_test.dart` | استئناف VPN، عدم التشغيل فوق VPN آخر أو دون موافقة، فشل مُصنّف، عقد القناة (أسماء الطرق والمعاملات وتحويل الأخطاء وتحليل البيانات الناقصة)، تحقق النطاق |
| `test/app/redirect_test.dart` | سياسة التوجيه |
| `test/app/app_flow_test.dart` | الإعداد الأول، شرح VPN ثم موافقة النظام، رفض الموافقة، VPN آخر، بوابة PIN للفئات وقائمة السماح، إضافة نطاق محظور مع التحقق |
| `test/app/layout_test.dart` | كل الشاشات (منها القوائم والسجل) على 5 مقاسات × حجمي خط، بلا overflow |

**Kotlin — 45 اختبار JUnit** (`cd android && ./gradlew test`)

| الملف | ما يغطيه |
|---|---|
| `engine/DomainNameTest.kt` | التطبيع، IDN، رفض المشوّه وعناوين IP، مرشحات اللاحقة، عدم المطابقة الجزئية |
| `engine/RuleEngineTest.kt` | الفئة مفعّلة/معطّلة، الحماية متوقفة، النطاقات الفرعية، الإيجابيات الكاذبة، قاعدة SAFE الأدق، المجهول = ALLOW، خطاف Strict Mode، قائمة السماح فوق كل شيء، قائمة الحظر المخصصة، القواعد المعطّلة، المصنّف، قوائم hosts |
| `engine/DnsFilterTest.kt` | IPv4/UDP والـchecksums، NXDOMAIN بالمعرّف والسؤال نفسيهما، التمرير وSERVFAIL، إسقاط غير DNS/TCP/IPv6/المجزأ، حلقات الضغط، fuzzing |
| `engine/LoggingStatusTest.kt` | ما يُسجَّل فقط، إزالة التكرار، التقليم، الإحصاءات اليومية/الأسبوعية/حسب الفئة، انتقالات حالة VPN |
| `data/SqliteStoresTest.kt` | SQLite الحقيقي عبر Robolectric (API 24 و34): CRUD، البحث الحرفي، العدادات، التقليم |

**ما تم التحقق منه فعليًا في بيئة التطوير، وما لم يتم:**

- ✅ اختبارات Flutter الـ73 و`flutter analyze` نظيف.
- ✅ اختبارات محرك Kotlin الـ45 تعمل وتنجح على JVM.
- ✅ طبقة Android كاملة مُترجمة بنجاح أمام إطار Android API 36
  (`android-all`) وFlutter embedding.
- ✅ كل عبارات SQL نُفّذت على SQLite حقيقي (والاستعلام يستخدم الفهرس).
- ❌ `SqliteStoresTest` (Robolectric) لم يُشغَّل: يعتمد على
  `androidx.test` من Google Maven المحجوب في البيئة.
- ❌ لم يُبنَ APK ولم يُختبر على جهاز. خطة الاختبار اليدوي:
  [`docs/MANUAL_TESTING.md`](docs/MANUAL_TESTING.md)، وتقرير محاولة التحقق
  على جهاز حقيقي (لم تُنفَّذ، مع الأسباب و3 أخطاء أُصلحت):
  [`docs/PHASE_2_REAL_DEVICE_TEST.md`](docs/PHASE_2_REAL_DEVICE_TEST.md).

---

## خارطة الطريق

- **المرحلة 3 (مقترحة):** مصدر قوائم فئات موثوق وموقّع (`RemoteRuleSource`)
  مع تحديثات تفاضلية؛ فرض SafeSearch عبر DNS (CNAME إلى
  `forcesafesearch.google.com` / `strict.bing.com` / `restrict.youtube.com`)؛
  حجب نطاقات DoH المعروفة لتقليل التجاوز؛ دعم DNS عبر TCP؛ إقفال مبني على
  `elapsedRealtime`.
- **لاحقًا:** Strict Mode، تصنيف محلي بالذكاء الاصطناعي، حماية على مستوى
  التطبيقات، لوحة عائلية بمزامنة مشفّرة طرفيًا، Device Owner اختياري.
