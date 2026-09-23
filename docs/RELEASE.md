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

## 6. مسار الإصدار

1. **اختبار داخلي** (Play Internal testing، حتى 100 مختبر): نسخة `prod`.
   اتبع `TEST_MATRIX.md` وسجّل النتائج في `DEVICE_TEST_LOG.md`.
2. **اختبار مغلق** (Closed testing): مجموعة مختبرين حقيقيين، أسبوعان على
   الأقل. المختبرون يرسلون «الإعدادات ← التشخيص ← نسخ» مع كل مشكلة.
3. **اختبار مفتوح** (اختياري): فقط بعد أن تصبح نتائج المصفوفة PASS للحالات الأساسية.
4. **الإنتاج:** بعد اكتمال `RELEASE_CHECKLIST.md`.

رقم الإصدار: زِد `version` في `pubspec.yaml` و`AppInfo` في `lib/app/app_info.dart`
معًا (اختبار آلي يتحقق من تطابقهما).
