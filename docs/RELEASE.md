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

## 5. Build flavors

لم تُضف. التطبيق بلا خوادم، فلا فرق بين dev وprod. تُضاف عند إضافة خادم (انظر `PHASE_6_SECURITY.md` §10).
