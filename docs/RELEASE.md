# بناء الإصدار (Release)

## 1. مفتاح التوقيع (مرة واحدة)

```powershell
keytool -genkey -v -keystore C:\keys\safeguard-upload.jks -keyalg RSA -keysize 4096 -validity 10000 -alias upload
```

احفظ ملف `.jks` وكلمات المرور **خارج المستودع** ومعها نسخة احتياطية آمنة. فقدانه يعني عدم القدرة على تحديث التطبيق، إلا إذا كنت تستخدم Play App Signing.

## 2. `android/key.properties` (لا يُرفع إلى git؛ موجود في `.gitignore`)

```properties
storeFile=C:/keys/safeguard-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

المسار نسبي إلى مجلد `android/` أو مطلق. إذا غاب الملف أو نقص أي حقل، يُوقّع البناء بمفتاح debug: صالح للتجربة على جهازك فقط، ويرفضه Google Play.

## 3. البناء

```powershell
flutter clean
flutter pub get
flutter build appbundle --release   # للرفع إلى Google Play
flutter build apk --release         # للتثبيت المباشر
```

- الإصدار من `pubspec.yaml`: `version: 1.5.0+6` يعني versionName 1.5.0 وversionCode 6. زِد الرقم بعد `+` في كل رفع.
- الإعدادات في `android/app/build.gradle.kts`:
  - R8 (`isMinifyEnabled`) وتقليص الموارد (`isShrinkResources`)
  - `isDebuggable = false`
  - قواعد `proguard-rules.pro`، ومنها إزالة `Log.v/d/i`
- القوائم المضمّنة (`*.sgbl`) تبقى غير مضغوطة لأنها تُقرأ بـ mmap.

## 4. التحقق بعد البناء

1. ثبّت الإصدار على جهاز: `flutter install --release` أو `adb install`.
2. فعّل الحماية، وتحقق من:
   - حجب نطاق من القوائم
   - البحث الآمن
   - حماية تطبيق
   - فحص نص بالذكاء الاصطناعي
   - صحة الحماية
3. تأكد أن `adb logcat -s SafeGuard` لا يُظهر نطاقات أو نصوصًا.
4. إن فشل شيء في الإصدار فقط، فالسبب غالبًا R8. أرسل رسالة الخطأ لتُضاف قاعدة `-keep` محددة.

## 5. نسخ البناء (Flavors)

| النسخة | الحزمة | الاسم | الاستخدام |
|---|---|---|---|
| `prod` (الافتراضية) | `com.safeguard.app` | SafeGuard | Google Play بكل مساراته (داخلي، تجريبي مغلق/مفتوح، إنتاج) |
| `staging` | `com.safeguard.app.staging` | SafeGuard Beta | اختبار داخلي بتثبيت مباشر، بجانب نسخة الإنتاج |
| `dev` | `com.safeguard.app.dev` | SafeGuard Dev | التطوير |

```powershell
flutter run                                   # prod (default-flavor في pubspec)
flutter run --flavor dev
flutter build apk --release --flavor staging  # للمختبرين بالتثبيت المباشر
flutter build appbundle --release             # prod للرفع إلى Play
```

- لا فرق في الخوادم أو المفاتيح بين النسخ، لأن التطبيق لا يتصل بأي خادم.
- بيانات الاختبار (قواعد تجريبية) تُزرع فقط في بناء **debug** لأي نسخة. نسخة release لا تحتويها.
- `MockClassifier` موجود في `src/test` فقط.

## 6. قنوات الإصدار: Development → Internal → Beta → Production

| القناة | النسخة | من يستلمها | شرط الانتقال للتالية |
|---|---|---|---|
| **Development** | `dev` debug، كل push | المطوّر | CI أخضر (تنسيق، تحليل، اختبارات Flutter وKotlin/Robolectric، lint، بناء) |
| **Internal** | `prod` release، Play Internal testing | فريق صغير (≤100) | صفوف `TEST_MATRIX.md` الأساسية PASS على جهازين حقيقيين على الأقل |
| **Beta** | `prod` release، Play Closed testing (ثم Open اختياريًا) | مختبرون حقيقيون، أسبوعان على الأقل | لا أعطال حرجة، ولا انقطاع حماية غير مفسّر في الملاحظات |
| **Production** | `prod` release، طرح تدريجي 10% ← 50% ← 100% | الجميع | `RELEASE_CHECKLIST.md` مكتمل |

نسخة `staging` للتثبيت المباشر عند المختبرين الداخليين بجانب نسخة الإنتاج.

## 7. الترقيم (SemVer)

`MAJOR.MINOR.PATCH+versionCode` في `pubspec.yaml` و`lib/app/app_info.dart`
(اختبار آلي يتحقق من التطابق، ومسار الإصدار يتحقق أن الوسم `vX.Y.Z` يطابق pubspec).

- **PATCH:** إصلاحات فقط، ومنها الأمنية.
- **MINOR:** ميزات أو ترحيلات إضافية لقاعدة البيانات.
- **MAJOR:** تغيير يكسر التوافق، مثل حذف إعداد أو صيغة تخزين.
- **versionCode:** يزيد دائمًا بمقدار واحد على الأقل مع كل رفع.

## 8. محتوى كل إصدار (إلزامي)

1. قسم في `CHANGELOG.md` يحوي: الإضافات، الإصلاحات، **ملاحظات الترحيل**،
   **ملاحظات الأمان** عند الحاجة، و**خطة التراجع**.
2. نتائج CI على الوسم نفسه.
3. تحديث `TEST_MATRIX.md` و`DEVICE_TEST_LOG.md` بالنتائج الفعلية على الأجهزة.
4. نص «ما الجديد» للمتجر بالعربية والإنجليزية، دون أي وعود بحماية كاملة.

## 9. التراجع (Rollback)

- **قبل 100%:** أوقف الطرح التدريجي في Play Console. من لم يحدّث لا يتأثر.
- **بعد النشر:** Play لا يسمح بالرجوع إلى versionCode أقل. التراجع يعني
  إصدارًا جديدًا (PATCH، versionCode أعلى) يحمل الكود السابق.
- **البيانات:** الترحيلات إضافية فقط، فالإصدار السابق يقرأ بيانات الإصدار
  الأحدث (`docs/DATABASE_MIGRATIONS.md`). إذا اضطر إصدار أقدم لإعادة بناء
  القاعدة، تُستعاد قوائم المستخدم من النسخة الاحتياطية الخاصة.
- **القواعد والنماذج (مستقبلًا):** تُسحب عبر حزمة موقّعة أحدث، و`expiresAt`
  يوقف الحزمة السيئة تلقائيًا (`docs/UPDATE_ARCHITECTURE.md`).

## 10. CI/CD

- `.github/workflows/ci.yml`: كل push وPR. تنسيق، `flutter analyze`،
  `flutter test`، `testProdDebugUnitTest` (JVM + Robolectric)،
  `lintProdDebug`، بناء debug لنسختين، وبناء release غير موقّع للتحقق من
  R8، وفحص الأسرار عبر gitleaks.
- `.github/workflows/release.yml`: يعمل على وسوم `v*.*.*` فقط، داخل بيئة
  `release` المحمية. يكتب `key.properties` في مجلد مؤقت من أسرار CI،
  ويبني AAB موقّعًا، ثم يحذف مواد التوقيع.
- `.github/dependabot.yml`: تحديثات pub وGradle وActions.
- لا أسرار في المستودع أبدًا. الأسرار المطلوبة موثقة في رأس `release.yml`.

> **ملاحظة:** ملفات CI كُتبت في المرحلة 8 ولم تُشغَّل بعد على GitHub من بيئة
> التطوير. أول تشغيل قد يحتاج تعديلات صغيرة، مثل أسماء المهام مع النسخ.
