# Final project audit — SafeGuard 1.8.0+9 (after the final AI phase)

Every statement is labelled:

- **VERIFIED:** demonstrated by a test, a build or a device run named next
  to it.
- **NOT VERIFIED:** implemented or designed, but not demonstrated where it
  matters (usually a real phone).
- **KNOWN LIMITATION:** a boundary of the design, of Android or of DNS
  filtering. It won't be "fixed".

SafeGuard does **not** provide 100% protection, 100% detection or 100%
security, and it can be bypassed (see Known limitations).

---

## 1. Evidence base

| Evidence | Result |
|---|---|
| `flutter analyze` (dev container) | VERIFIED: no issues |
| `dart format --set-exit-if-changed` | VERIFIED: clean |
| `flutter test` (dev container) | VERIFIED: **196 passed, 0 failed** |
| Kotlin engine tests on the JVM (dev container harness) | VERIFIED: **269 passed, 0 failed** |
| Android layer compile check against android-all 16 (harness) | VERIFIED: compiles (with a local `R` stub) |
| GitHub Actions CI, run 35894524054 on `7793a8a` | VERIFIED: **all 3 jobs green**. Flutter: format, analyze, **196 tests passed**. Android: `testProdDebugUnitTest` (JVM engine + Robolectric SQLite incl. `MigrationTest`), `lintProdDebug` (0 errors), debug APKs dev + prod, **unsigned release APK prod with R8** (`app-prod-release.apk`, 67.5 MB, all ABIs). Secret scanning (gitleaks): clean |
| Earlier CI runs (same day) | Failed and fixed, see §3a: missing Gradle wrapper, a test using a JVM-only API, 15 lint errors |
| Real device (owner): Infinix X6528, Android 13, **debug build of Phase 5** | VERIFIED there only: app runs, SafeSearch enforced, custom-blocklist domain blocked (DEVICE_TEST_LOG D1–D3) |
| Real device, any Phase 6–8 build | **NOT VERIFIED:** not run |
| Signed release AAB on a device | **NOT VERIFIED** |

## 2. Architecture

- VERIFIED (tests): the pure Kotlin engine (`engine/**`) holds all
  decisions: DNS parsing, rules, lists, search, AI, health, recovery,
  updates, explanations, trace, backup format. The Android layer is thin
  adapters. Flutter holds UI and state, with a stringly typed channel
  guarded by contract tests.
- KNOWN DEBT: see `ARCHITECTURE_REVIEW.md`. The main items are the
  `ProtectionManager` god object (A1), the oversized `ProtectionEngine`
  interface (A3), and cross-language duplication (A4).
- The update system (`engine/updates`) is VERIFIED by 15 tests. It is
  **not wired** to any transport or rule loading, and no publisher key is
  pinned. NOT VERIFIED end to end, by design, because there is no server.

## 3. Security

| Item | Status |
|---|---|
| PIN: PBKDF2 120k + salt, Keystore-encrypted; lockout escalation; clock-change resistance; app restart | VERIFIED (pin_test, phase5/6 tests) |
| PIN on a device: reboot during lockout, clock change | NOT VERIFIED |
| HMAC key non-exportable in Keystore | NOT VERIFIED on device (code compiles; JVM uses a raw-key provider) |
| No secrets or cleartext endpoints / WebViews in source | VERIFIED (`Phase6Test`; gitleaks: see CI row) |
| Log calls constant (no user data) | VERIFIED (`Phase6Test`) |
| Channel input validation, parameterised SQL | VERIFIED by review + tests for validators; NOT fuzzed |
| DB errors fail closed to bundled lists | VERIFIED (`Phase7Test`) |
| Signed update verification (signature, schema, downgrade, expiry, checksum, parse, tamper-at-rest) | VERIFIED (`UpdateStoreTest`) |
| VPN revoke / recovery race fixes | NOT VERIFIED (Android-only code paths; review + compile) |
| Release R8 build | VERIFIED **builds** (CI unsigned release APK). NOT VERIFIED that it **runs** correctly on a device |
| DNS parser robustness against fuzzed input | NOT VERIFIED (no fuzzing) |

**Issues found and fixed across Phases 6–8:**
- Plaintext HMAC key in prefs.
- Clock-change PIN lockout bypass.
- Exception text in logs.
- Missing retention control.
- Invalid channel args returning INTERNAL.
- Downgrade crash.
- Disk-full crash.
- DB error ending filtering.
- VPN revoke races.
- Safe Mode silently exited on app open.
- App-protection relaunch bypass.
- Stale rule cache.
- Out-of-order status.
- Hanging futures.
- Malformed truncated DNS reply.
- Lost concurrent telemetry/crash writes.
- Lost user lists after a DB rebuild.
- Statistics crash on Android 7.x (`java.time`).
- Android 16 back gesture on the protected-app screen.

### 3a. Found by CI in Phase 8 (fixed)

The first real Android build (CI) found issues that the dev container, which has no
Android SDK, could not:
- **Statistics crashed on Android 7.0/7.1** (`java.time` needs API 26;
  `minSdk` is 24). Replaced with `java.util.Calendar`; a new test covers
  local midnight in a non-UTC time zone (lint `NewApi`, 14 errors).
- **Back gesture on Android 16+** (predictive back) didn't call
  `onBackPressed`, so the "protected app" screen closed instead of going
  home. It now registers an `OnBackInvokedCallback` (lint
  `GestureBackNavigation`). NOT VERIFIED on a device.
- `AiBenchmarkTest` used `java.lang.management` (not in `android.jar`); it
  now reaches it reflectively.
- CI didn't generate the gitignored Gradle wrapper.

Remaining lint **warnings** (32; not errors): `UseKtx` style suggestions,
newer Gradle / Robolectric versions available, `UnusedAttribute`
(`isAccessibilityTool` is ignored below API 31, as intended), an unused
color, and `StaticFieldLeak` on `ProtectionManager`. The last one is a
false positive: the singleton holds `applicationContext`.

## 4. Privacy

- VERIFIED (tests):
  - The diagnostics whitelist and sanitiser drop domains, queries, PIN
    and free text.
  - Crash records store no error messages.
  - Telemetry is off by default, uses a closed set of events, and opting
    out deletes it.
  - The decision trace is content-free, off by default and memory only.
  - The feedback preview equals what is copied.
  - Protection code doesn't import billing code.
- VERIFIED (config): `allowBackup=false`; data extraction rules exclude
  all domains; the config backup lives in `noBackupFilesDir`.
- NOT VERIFIED on device: that no data appears in logcat in a release
  build (method in RELEASE.md §4).
- The app makes no network requests of its own. It forwards only the
  user's DNS to the network's resolver (fallback 1.1.1.1 / 9.9.9.9).

## 5. Performance

- VERIFIED on JVM (container, not a phone), from `PERFORMANCE.md`:
  - rule decision 5.7 µs on a cache miss, 0.4 µs on a hit;
  - bundled-list lookup 7.2 µs;
  - DNS packet to decision 0.57 µs;
  - text inference ~35 µs.
- NOT VERIFIED: phone startup, memory, CPU, battery, DNS latency, and the
  battery impact of the 15-minute monitor. All are NOT MEASURED.

## 6. Reliability

- VERIFIED (JVM):
  - Recovery backoff: VPN ≤3 attempts per 10 min; monitor 1 → 4 → 16 min
    … 4 h, ≤6 per day.
  - Monitor notifies once per degradation and clears when healthy.
  - Log write failures are swallowed and counted.
  - Backup format round-trips and rejects malformed input.
- NOT VERIFIED on device:
  - network switching;
  - airplane mode;
  - reboot with or without Always-on;
  - OEM battery killers (XOS);
  - low memory;
  - storage full;
  - a real DB corruption restore;
  - the alert notification appearing.
- VERIFIED on CI (Robolectric): `MigrationTest` (v1 → v4 keeps user rules and log) and the SQLite store tests, as part of `testProdDebugUnitTest`.

## 7. Testing

| Area | Automated | Real device |
|---|---|---|
| App start, onboarding, wizard, PIN | VERIFIED (widget) | NOT VERIFIED (Phase 5 app start only) |
| VPN / DNS filtering | VERIFIED (engine + fake) | Custom blocklist VERIFIED (Phase 5); lists NOT VERIFIED |
| Search filtering / SafeSearch | VERIFIED (engine) | SafeSearch VERIFIED (Phase 5); in-app search NOT VERIFIED |
| App protection | VERIFIED (logic) | NOT VERIFIED |
| AI | VERIFIED (JVM, eval set) | NOT VERIFIED |
| Modes, allow/block lists, statistics, logs, privacy controls, reset | VERIFIED (widget + engine) | NOT VERIFIED |
| Reboot, network switching | — | NOT VERIFIED |
| Release build | VERIFIED: unsigned release APK builds with R8 on CI; signed AAB not built | NOT VERIFIED |
| English / Arabic UI | VERIFIED (i18n_test: no Arabic leaks on any screen in English, LTR) | NOT VERIFIED |
| Layout (5 sizes incl. 320 px, 1.3× text) | VERIFIED | — |

The full requested device regression (app starts … release build works)
has **not been executed on a real device** by the developer. See
TEST_MATRIX.md (M1–M45): 3 PASS, 1 N/A, 1 BLOCKED-here, the rest NOT
EXECUTED.

## 8. Android compatibility

- `minSdk 24` (Android 7.0). `targetSdk` from Flutter. Code paths
  gated for API 26 (channels), 29 (metered), 33 (notification
  permission).
- NOT VERIFIED on Android 7–9, 14, 15 and 16 devices.
- KNOWN LIMITATION: Android 13+ "restricted settings" can block
  accessibility for sideloaded builds. The app reports it as
  "unavailable".

## 9. Known limitations

- DNS-level only: no page, image or post content filtering. Instagram and
  TikTok posts can't be filtered.
- Encrypted DNS inside apps or browsers (DoH/DoT), Chrome Secure DNS,
  Private DNS (strict), another VPN, or hard-coded resolvers can bypass
  filtering. SafeGuard detects Private DNS and other VPNs, not all DoH.
- One VPN at a time. SafeGuard stops rather than fighting another VPN.
- The device owner can disconnect the VPN, force-stop, clear data or
  uninstall. There is no device-owner / MDM mode, by design.
- The AI is a small text model with limited accuracy (see PHASE_4_AI.md).
  No image model ships. It runs only on SafeGuard's own search and on
  images the user picks.
- No large lists for violence, gore or dangerous content.
- Bundled lists are automatically aggregated and can contain false
  positives.
- Always-on VPN state can't be read by apps.
- Alerts need notification permission. Monitor checks can be delayed
  while the phone sleeps (Doze).
- Reboot + clock change can end one PIN lockout early.

## 10. Known risks

1. **First release build on a device.** R8 and the flavours now build on
   CI, but no release build has run on a phone. R8 can still strip
   something used only at runtime.
2. **OEM background killing** (Infinix/XOS, some Samsung / Xiaomi
   settings) may stop the VPN. Untested.
3. **Play review** of the VpnService and Accessibility declarations; the
   declaration video isn't recorded yet.
4. **Unmeasured battery impact** of the monitor on real devices.
5. The **bundled list provenance** needs review by the publisher
   (LISTS.md).
6. **No fuzzing** of the packet parser.
7. **No live update channel:** lists age until the next app release.

## 11. Technical debt

See ARCHITECTURE_REVIEW.md. The top items are A1 (god object), A3 (engine
interface), A4 (Dart/Kotlin duplication), A2 (stringly-typed channel),
A12 (debug fixtures in main), and A14 (fuzzing). In addition, the
`DnsForwarder` has no TCP fallback for truncated answers (documented since
Phase 2).

## 12. Recommended next priorities

1. **Real-device regression on the release build** (TEST_MATRIX M1–M45) on
   at least three phones: Infinix/XOS, a Pixel or near-stock device, and
   a Samsung. Record the results in DEVICE_TEST_LOG.md.
2. **Measure performance and battery** on those phones (PERFORMANCE.md
   method).
3. **Fix what CI and the devices find.** Get CI green on every push.
4. Refactor A1 and A3 behind the existing tests.
5. Add larger, licensed lists for violence / gore / dangerous content,
   and an update transport using the implemented verifier, with the
   publisher keys held offline.
6. Fuzz the DNS parser in CI.
7. Only then run a closed beta, then a production staged rollout.

## 13. AI Content Shield (final AI phase, 1.8.0+9)

Details: docs/AI_CONTENT_SHIELD.md. Manual plan: docs/FINAL_AI_TESTING.md.

| Item | Status |
|---|---|
| Engine: labels, policy integration through the existing decision engine, temporal confirmation, sampling gate, watchdog, status resolver, model-pack parser, image classifier failure states, visible-text privacy filter | VERIFIED (JVM: `ShieldPolicyTest`, `ContentShieldTest`; 32 tests) |
| Real text model on page-style text (66 hand-written EN/AR sentences) | VERIFIED as measured: 0/40 safe blocked (NORMAL and STRICT), 13/21 risky blocked in NORMAL, 16/21 in STRICT (`ShieldTextEvalTest`). Small set: **not** a real-world accuracy figure |
| Text inference latency | 0.58 ms median on a desktop JVM. **NOT MEASURED on a phone** |
| Privacy guarantees in code (no logging/storage/network/capture/overlay in the shield path; config lists exactly the supported apps; no new permission) | VERIFIED (`ShieldSourceAuditTest`) |
| Dart ↔ Kotlin ids, parsing, screen states, disclosure, PIN on loosening, English/Arabic, layout | VERIFIED (`content_shield_test`, `i18n_test`, `layout_test`) |
| Android service compiles against android.jar (harness) | VERIFIED |
| Android build, lint, Robolectric, R8 release build with the shield | VERIFIED on CI: run 35908219787 on `e21f480`, all jobs green (Flutter tests, Kotlin + Robolectric tests, lint, debug APKs, unsigned release APK with R8, gitleaks) |
| Shield on a real device (any app) | **NOT VERIFIED:** every scenario in FINAL_AI_TESTING.md is NOT EXECUTED |
| Image / video classification | **NOT IMPLEMENTED as working AI:** no image model bundled, no runtime compiled in; pipeline tested only with a fixed-output test double. The UI reports it as unavailable |
| Screen capture (MediaProjection) | NOT IMPLEMENTED (designed; waits for an image model) |
| Play approval of a second accessibility service with window-content access | NOT VERIFIED (declaration drafted, video not recorded) |

KNOWN LIMITATIONS:
- **Text only:** photos, video, reels and stories are not checked.
- **Coverage depends on the app:** apps may expose little text, use secure
  surfaces or change their UI at any time.
- **Blocking behaviour:** a block sends the user home; it can't hide a
  single post.
- **Private messages:** those displayed in supported apps are processed in
  memory like any text.
- **The user can disable it:** the device owner can turn the service off in
  Android settings.
- **Model quality:** the text model misses many risky texts (about 4 in 10
  on the measured set in NORMAL).

Issues found and fixed during this phase:
- **Temporal confirmer (design flaw):** a safe sample followed by a risky
  one produced a diluted "OK" result instead of "pending". The gate would
  then skip the unchanged risky screen for good. Found by a unit test and
  fixed.
- **Shield text budget below the gate's maximum rate:** continuous
  scrolling would have produced UNKNOWN results. Fixed.
- **Service robustness:** a block could fire after the service was
  destroyed; `execute` after shutdown would throw. Both fixed.
