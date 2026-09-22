# SafeGuard

**حماية المحتوى على مستوى جهاز Android. عربي أولًا، خاص، وصريح بشأن حدوده.**

SafeGuard تطبيق Flutter + Kotlin يهدف إلى حجب المحتوى غير المرغوب فيه
(جنسي، عنف، محتوى دموي، مقامرة، مخدرات، محتوى خطِر، بحث غير آمن) على
مستوى الشبكة في الجهاز، دون حسابات أو خوادم.

> **الحالة: المرحلة الأولى (Phase 1).** هذا الإصدار يبني الأساس الكامل:
> البنية المعمارية، نظام التصميم، واجهة عربية RTL، رمز PIN آمن، حفظ
> التفضيلات، والتنقل. **لا يحجب أي محتوى فعليًا بعد.** طبقة الفلترة
> (VpnService + DNS) هي المرحلة الثانية، والتطبيق يوضّح ذلك للمستخدم داخل
> الواجهة بدل الادعاء بحماية غير موجودة.

---

## ما يستطيعه Android وما لا يستطيعه

| الوظيفة | ممكنة؟ | الطريقة / الحد |
|---|---|---|
| حجب نطاقات (مواقع) لكل التطبيقات | ✅ | `VpnService` محلي يعترض استعلامات DNS فقط، على الجهاز (المرحلة 2) |
| فرض البحث الآمن (Google/Bing/YouTube) | ✅ جزئيًا | إعادة توجيه DNS إلى نطاقات SafeSearch الرسمية (المرحلة 2) |
| قراءة محتوى الصور/المنشورات داخل تطبيقات أخرى | ❌ | Android يعزل التطبيقات، ولا يوجد API لذلك |
| الحجب إن كان المتصفح يستخدم DNS مشفّرًا خاصًا به (DoH) أو VPN آخر | ⚠️ | قد يتجاوز الفلترة. يمكن تخفيفه بحجب نطاقات DoH المعروفة، لكن لا يمكن ضمانه |
| منع إزالة التطبيق أو مسح بياناته | ❌ بدون Device Owner | يتطلب Device Admin/Device Owner أو Family Link. خارج نطاق المرحلة 1 |
| استخدام Accessibility Service لقراءة الشاشة | ⚠️ مقيّد | Google Play يقيّد استخدامه بشدة لغير أغراض الإتاحة. **لن نعتمد عليه** |

هذه الحدود معروضة للمستخدم في شاشة **الحالة ← حدود الحماية**.

---

## البنية المعمارية

Clean Architecture خفيفة، مقسّمة حسب الميزة (feature-first). كل ميزة فيها
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
│   ├── platform/secure_screen.dart  # Platform Channel ← MainActivity.kt
│   └── utils/
└── features/
    ├── protection/   # ProtectionState، الفئات، ProtectionEngine (نقطة ربط المرحلة 2)
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
- **نقطة ربط المرحلة 2:** `ProtectionEngine` واجهة في الـdomain.
  المرحلة 1 تستخدم `UnavailableProtectionEngine` التي تعلن
  `EngineStatus.notInstalled`، والواجهة تعرض ذلك بصدق.

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

**ما يتطلب رمز PIN:** إيقاف الحماية، تعطيل أي فئة، إيقاف قفل التطبيق،
تغيير الرمز، حذف البيانات. **التشديد (التفعيل) لا يتطلبه أبدًا.**

**Android**

- `allowBackup="false"` + `dataExtractionRules` تستثني كل شيء (مفاتيح
  Keystore لا تنتقل بين الأجهزة أصلًا).
- لا صلاحيات في المرحلة 1، ولا صلاحية `INTERNET` في نسخة release.
  لا شيء يغادر الجهاز.
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
| مكونات الميزة | `features/protection/presentation/protection_ui.dart` | `ProtectionStatusCard` `ProtectionToggle` `CategoryTile` |

**قرارات UX**

- **الرئيسية تجيب على سؤال واحد:** "هل أنا محمي، ومن ماذا؟". بطاقة الحالة ثم
  الفئات. الإحصاءات والطبقات في تبويب "الحالة".
- **إيقاف الحماية هو الزر الأهدأ** (outlined)، والتفعيل هو الزر البارز.
- **Onboarding شاشة واحدة** (لا carousel): ما يفعله التطبيق، كيف يعامل
  البيانات، وحدوده، ثم إعداد PIN مباشرة.
- **لوحة الأرقام LTR دائمًا** (1-2-3 من اليسار) حتى في RTL، كما في كل
  تطبيقات البنوك والاتصال العربية.
- **لا أرقام وهمية:** الإحصاءات تُعرض "—" مع شرح، بدل أصفار مختلقة.
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

| الملف | ما يغطيه |
|---|---|
| `test/core/pbkdf2_test.dart` | متجهات RFC 7914 §11 الرسمية، المقارنة الثابتة، تفرّد الملح |
| `test/features/pin_test.dart` | قواعد الرمز، عدم تخزين النص، ملح مختلف لكل مرة، الإقفال والتصاعد، استمرار العدّاد، تغيير الرمز يتطلب الحالي، أخطاء التخزين، البيانات التالفة |
| `test/features/protection_settings_test.dart` | حالة الحماية (JSON، التوافق المستقبلي، fail-closed)، الحفظ والتراجع عند الفشل، إعدادات التطبيق |
| `test/app/redirect_test.dart` | سياسة التوجيه كاملة، بما فيها منع إعادة التوجيه لخارج التطبيق |
| `test/app/app_flow_test.dart` | تدفقات حقيقية: الإعداد الأول، رفض الرمز الضعيف، بوابة PIN عند التعطيل وعدمها عند التفعيل، شاشة القفل، RTL |
| `test/app/layout_test.dart` | كل الشاشات على 5 مقاسات (320×568 حتى تابلت وأفقي) × حجم خط 1.0 و1.3، بلا أي overflow |

---

## خارطة الطريق

- **المرحلة 2:** `VpnService` محلي لفلترة DNS + قوائم نطاقات لكل فئة +
  SafeSearch + Platform Channel للمحرك + إحصاءات محلية حقيقية.
- **لاحقًا:** إقفال مبني على `elapsedRealtime`، دعم Device Owner اختياري
  لمنع الإزالة، وتوطين إنجليزي عبر ARB.
