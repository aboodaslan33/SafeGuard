# Phase 3 — Search & App Protection: Testing

## Status

| | Result |
|---|---|
| Automated tests (Flutter) | **93/93 PASS** (73 from Phases 1–2 unchanged + 20 new) |
| Automated tests (Kotlin, JVM) | **90/90 PASS** (45 from Phase 2 unchanged + 45 new) |
| `flutter analyze` | PASS, no issues |
| Android layer compile check (API 36 framework jar) | PASS |
| `cd android && ./gradlew test` | **NOT RUN.** No Android SDK here; `dl.google.com` / Google Maven are blocked by network policy. The same Kotlin test sources ran through a JVM Gradle harness instead (see below). |
| APK build | **NOT RUN** (same reason) |
| Manual tests on a device | **NOT EXECUTED.** No device available. Nothing below is claimed as passed. |

## Scope implemented

The phase specification received for this work began at section 13; sections
1–12 were not available. Implemented interpretation, following "Phase 3 =
rule-based/query layer; Phase 4 = AI":

1. **SafeSearch** on Google, Bing, DuckDuckGo and YouTube, enforced by the
   existing local VPN with each provider's official DNS mechanism (CNAME to
   `forcesafesearch.google.com`, `strict.bing.com`, `safe.duckduckgo.com`,
   `restrict[moderate].youtube.com`).
2. **Search query classification** (normalizer → `SearchClassifier` →
   `SearchPolicy`), applied to searches submitted through SafeGuard's own
   search box. SafeGuard does **not** read what is typed in other apps.
3. **App Protection**: the user picks apps. When one comes to the
   foreground, SafeGuard sends the user home and shows its "app protected"
   screen. This uses an opt-in Accessibility service limited to
   window-change events without window content.
4. **Privacy-safe events** with source/category/action/confidence/rule type.

## Test objectives

- Search normalization is stable across Arabic, English, mixed text,
  diacritics, Unicode variants, punctuation and repeated characters.
- Classification detects every category, allows SAFE/UNKNOWN, and avoids
  substring false positives.
- The policy respects category toggles, thresholds and UNKNOWN.
- **No query text, password or token ever reaches the event store.**
- SafeSearch rewrites only search front-ends, never other Google services,
  and fails closed (SERVFAIL) rather than leaking the unrestricted name.
- App Protection validates packages and never protects system-critical apps.
- The Accessibility state is reported truthfully (unavailable / declined /
  disabled / enabled).
- The Flutter ↔ Kotlin contract (names, parameters, types, errors) is stable.
- Phase 1 and 2 behaviour is unchanged (all earlier tests unmodified and passing).

## Automated tests

### Kotlin (`android/app/src/test/kotlin/.../engine/`)

| Class | Tests | Covers |
|---|---|---|
| `SearchNormalizerTest` | 8 | Arabic diacritics/tatweel/letter variants, English, mixed language, whitespace, punctuation, full-width Unicode, Latin accents, repeated characters, Arabic prefixes, input cap |
| `SearchClassifierTest` | 9 | Every category in EN+AR, SAFE/UNKNOWN, substring false positives (essex, sussex, gorey, methodology), protective context ("sex education", "علاج إدمان"), ambiguous weak terms, mixed-category queries, obfuscated spelling, rule ids instead of text, combined classifier (Phase 4 hook) |
| `SearchPolicyTest` | 7 | Category enabled/disabled, threshold exceeded/not exceeded/inclusive/per-category, UNKNOWN, SAFE, multiple categories, search protection off |
| `SearchPrivacyTest` | 5 | Sensitive query not stored, password/token-like input not stored, allowed queries not logged, keyed short hash, placeholder service |
| `LexiconIntegrityTest` | 1 | Unique ids, weights in range, every term normalizes |
| `SafeSearchTest` | 6 | Front-end mapping only, per-engine settings, full DNS path: CNAME + A synthesized from a compressed upstream answer, malformed upstream → SERVFAIL, HTTPS records → NODATA, block rules win, off/paused pass through |
| `AppProtectionTest` | 5 | Protected/unprotected package, protection off, add/remove, duplicate, invalid package names, not installed, exempt system apps, limit |
| `AccessibilityStateTest` | 4 | Unavailable, enabled (long and short component form), disabled, permission denied |
| Phase 2 suites | 45 | Unchanged |

A mutation check was also run: making the search recorder append the query
text to the stored event made `SearchPrivacyTest` fail (2 tests), confirming
the privacy tests detect leaks.

**How they were run:** a JVM Gradle harness compiles the pure `engine/`
package with these same test files, and type-checks the Android layer
(`AppGuardService`, `AppBlockedActivity`, stores, channel) against
`org.robolectric:android-all` (API 36) and the Flutter embedding jar.
`./gradlew test` in `android/` runs the same tests where the SDK exists.

### SQL

The v1 → v2 migration (`ALTER TABLE block_events ADD COLUMN …`,
`CREATE TABLE protected_apps`) and the new queries were executed against
desktop SQLite with a pre-existing v1 row, which kept its values and gained
the DNS defaults. Not validated on Android's SQLite.

### Flutter (`test/features/phase3_test.dart`, `test/app/layout_test.dart`)

| Group | Covers |
|---|---|
| Platform channel contract | Method names, parameter names/values, response parsing, malformed items skipped, `PlatformException` → typed `EngineFailure` with Arabic message, Phase 2 events without new fields still parse |
| `SearchSettings` | Which changes count as loosening (need PIN), tightening does not, defensive parsing defaults to strict |
| Controller sync | Search master switch ↔ Phase 1 "فلترة البحث" category, per-engine settings reach native, accessibility refresh |
| App rules | Add, duplicate, invalid, not installed, not allowed, remove |
| Screens | Blocked search → block screen and the logged subject contains no query words; typing alone triggers nothing (submit only); allowed search opens results; SafeSearch off needs PIN, on doesn't; disabling Search Protection needs PIN and can be cancelled; accessibility decline → "مرفوضة", accept → opens Android settings; unavailable state (restricted setting) explained; add app freely, removal needs PIN |
| Layout | Search Protection and App Protection screens at 5 sizes × 2 text scales, no overflow |

## Manual test cases (to run on a device)

Use a **debug** build. Private DNS: Off/Automatic. Chrome: Settings →
Privacy → *Use secure DNS* **off** (otherwise Chrome bypasses system DNS).

| # | Steps | Expected | Result |
|---|---|---|---|
| P3-1 | Protection ON, Search Protection ON. Open `https://www.google.com/search?q=test` in a browser. | Results show SafeSearch locked on. | NOT EXECUTED |
| P3-2 | Same with Bing and DuckDuckGo. | Strict/safe mode enforced. | NOT EXECUTED |
| P3-3 | YouTube app/site, mode Strict, then Moderate, then Off (PIN). | Restricted Mode on/on/off accordingly. Allow time for DNS caches. | NOT EXECUTED |
| P3-4 | Turn a SafeSearch engine off. | PIN required. | NOT EXECUTED |
| P3-5 | `adb shell ping -c1 mail.google.com` | Resolves normally (not rewritten). | NOT EXECUTED |
| P3-6 | Settings → حماية البحث → search "online casino". | Block screen (المقامرة); log shows "بحث · المقامرة" with a rule id + hash, no query words. | NOT EXECUTED |
| P3-7 | Search "weather tomorrow". | Browser opens results with the engine's safe parameter. | NOT EXECUTED |
| P3-8 | Disable the Gambling category, search "online casino". | Allowed. | NOT EXECUTED |
| P3-9 | Settings → حماية التطبيقات → تفعيل الخدمة → «لا أوافق». | Status "مرفوضة"; Android settings not opened. | NOT EXECUTED |
| P3-10 | تفعيل الخدمة → accept → enable "حماية التطبيقات في SafeGuard" in Android accessibility settings → return. | Status "مفعّلة". On a sideloaded APK, Android 13+ may show "Restricted setting": document what happened. | NOT EXECUTED |
| P3-11 | Add an app (e.g. a game). Open it. | Home screen, then "هذا التطبيق محمي". Back returns home, not to the app. Log shows "تطبيق محمي". | NOT EXECUTED |
| P3-12 | Remove the app. | PIN required; app opens normally afterwards. | NOT EXECUTED |
| P3-13 | Protection paused (PIN) and open the protected app. | Opens normally. | NOT EXECUTED |
| P3-14 | Disable the accessibility service in Android settings. | Status "غير مفعّلة"; protected apps open. SafeGuard doesn't prevent this. | NOT EXECUTED |
| P3-15 | Try to add Settings/Phone/launcher. | Not listed in the picker; rejected if forced. | NOT EXECUTED |
| P3-16 | Upgrade from a Phase 2 install with existing logs. | Old DNS events still listed; stats unchanged. | NOT EXECUTED |
| P3-17 | Battery: service enabled, 1 h normal use. | No measurable SafeGuard CPU/battery in system battery stats. | NOT EXECUTED |

Totals: 0 PASS, 0 FAIL, 17 NOT EXECUTED.

## Privacy validation

- Event store fields: timestamp, subject, category, source, action,
  confidence, rule type. Search subject = `<rule id>#<8-hex HMAC>`, with a
  per-install key in app-private storage, deleted by "حذف جميع البيانات".
- Only **blocked** searches create events. Allowed searches leave no trace.
- The query is sent to the native layer only on submit, used in memory,
  never returned to Flutter, never logged (logcat audit: no `Log.*` call
  includes user data; Flutter's logger is debug-only and logs errors only).
- The Accessibility service config has `canRetrieveWindowContent=false` and
  receives only `typeWindowStateChanged`. It knows the foreground package
  name, nothing else.
- No new `uses-permission` was added. Package visibility is limited to
  launcher/home/browser intents (no `QUERY_ALL_PACKAGES`).

## SafeSearch limitations

- Works only while the VPN runs and the app uses system DNS. Chrome
  "Secure DNS", Firefox DoH, Android Private DNS with a named provider, apps
  with hardcoded DNS, and other VPNs bypass it.
- Only Google, Bing, DuckDuckGo and YouTube. Other engines are not
  restricted.
- DNS caches (OS, browser) may keep an unrestricted answer for minutes
  after enabling.
- HTTPS/SVCB records for mapped names get an empty answer, so the browser
  uses the A/AAAA path.
- Google domains covered: `google.<cc>`, `google.com.<cc>`, `google.co.<cc>`
  (with or without `www`). Unusual Google search hostnames may be missed.

## App protection limitations

- Blocks opening the whole app. It cannot see or filter content inside apps.
- Needs the Accessibility service, which the user must enable and can
  disable at any time. Some devices/profiles don't allow it, and Android 13+
  can restrict it for sideloaded apps ("Restricted setting").
- Split-screen, picture-in-picture, and apps opened while SafeGuard's
  process is being restarted may briefly show the protected app.
- System-critical apps (SafeGuard, Settings, launcher, phone/dialer, system
  UI, permission controller, package installer) can never be protected, so
  the owner keeps control of the device.
- Google Play requires a policy declaration and prominent disclosure for a
  non-accessibility-tool use of the Accessibility API. The in-app
  disclosure exists; the Play Console declaration is a release task.

## Known Android limitations (unchanged from Phase 2)

One VPN at a time; the user can always disconnect the VPN, disable the
service, or uninstall; reboot recovery depends on Always-on VPN; OEM
battery management may stop background work.
