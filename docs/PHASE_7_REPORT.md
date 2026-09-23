# Phase 7 report: beta and release preparation

Version **1.6.0+7**. This phase prepares SafeGuard for beta testing. It
doesn't make it production-ready: real-device testing and a verified
release build are still missing (see `RELEASE_CHECKLIST.md`).

## 1. Production code review: bugs found and fixed

The review covered VPN, DNS, rules, logging, the channel, the database,
app protection and the Flutter controller. Each fix below has a
regression test where one was possible on the JVM or in widget tests.

| # | Bug (concrete scenario) | Severity | Fix | Test |
|---|---|---|---|---|
| B1 | Disk full / SQLite I/O error on the block-log thread → uncaught exception on an executor thread **kills the process**, so the VPN drops, restarts (sticky) and crashes again on the next block | High | Log writes/prunes wrapped; failures counted and shown in Diagnostics | `Phase7Test.logWriteFailureDoesNotThrow` |
| B2 | SQLite error during a rule lookup ends the DNS loop → tun torn down → device unfiltered after 3 recovery attempts | Medium | `CompositeRuleStore` catches primary-store errors: bundled lists keep blocking (fail closed), degraded answers aren't cached, DB layer reports unhealthy for 5 min | `databaseErrorKeepsBundledListsBlocking` |
| B3 | Race: another VPN takes over → the loop sees POLLHUP before `onRevoke` (binder thread) → stale recovery overwrites REVOKED with ERROR or **re-establishes and fights the other VPN** | Medium | Session identity (`tun === fd`), `revoked` flag, main-thread re-check, recovery cancelled on stop/start/destroy/revoke | Android-only (compiles; not device-tested) |
| B4 | "Another VPN took over" was never recorded as an incident (RUNNING → STOPPING → REVOKED hid it) | Medium | `onRevoke` reports REVOKED straight from RUNNING | Android-only |
| B5 | Opening the app after Safe Mode (or during a pause) silently restarted the VPN | Medium | Resume skips Safe Mode and pauses | `phase7_test` (3 cases) |
| B6 | App protection bypass: relaunch a blocked app within 1.5 s of pressing Home | Medium | De-dupe window reset when another app comes to the front | Android-only |
| B7 | Rule cache kept a stale "allow" computed while the lists were loading; `rulesReady` reported before the lists loaded | Low | Generation counter on invalidate; ready only after lists load | `lookupRacingAnInvalidateIsNotCached` |
| B8 | Status events could reach Flutter out of order (UI stuck on an old state); incident detection not thread-safe | Low | Post the current state on the main thread; synchronised detector | — |
| B9 | Package-manager IPC on the main thread on every window event | Low | 60 s cache | — |
| B10 | Channel detach left Dart futures (permission / image / export) pending forever | Low | Completed with `DETACHED` | — |
| B11 | Truncated DNS fallback reply had non-zero section counts (malformed) | Low | Counts zeroed, TC set | — |
| B12 | Failure messages and enum labels were frozen at first use (couldn't follow a language change) | Low | Getters | `i18n_test` |

Checked and fine (no change needed): the VPN doesn't need
`startForeground` (a VpnService with an established tun is bound by the
system), boot start errors are caught, no double tun, resources are
released on shutdown, the DNS parser is bounds-checked, WAL and downgrade
are handled, singletons hold only the application context.

## 2. Features added

- **English (LTR) UI** alongside Arabic (RTL). A setting in Settings and
  on the welcome screen, and all ~600 UI strings. The native "protected
  app" screen follows it. Android's accessibility strings follow the
  device language (`values` English, `values-ar` Arabic).
- **Onboarding:** 8 pages covering what it does, DNS protection, search
  protection, AI, permissions, local data, limitations (Android
  restrictions and encrypted DNS stated explicitly) and how to enable it.
- **First-run wizard "Enable SafeGuard Protection":**
  - 8 steps: mode → categories → apps → search → AI → PIN → permissions → verification.
  - The final result is **ACTIVE / PARTIAL / FAILED**, taken from native health. ACTIVE is never assumed.
  - Re-running it from Settings requires the PIN.
  - Deviation from the requested order: the PIN is created *before* the wizard, because the app already requires a PIN before Home. Step 6 therefore shows it as done and offers a change.
- **Setup assistant** (permission experience). It shows PROTECTED / PARTIALLY / NOT PROTECTED, then each of these checks with why it's needed, what depends on it, how to fix it, and an action button:
  - VPN consent and whether protection is running
  - another VPN
  - Private DNS
  - accessibility (only when apps are protected)
  - notifications (not used, explained)
  - battery optimisation
  - Always-on VPN (never claimed as on, because it isn't readable)

  It re-checks when the user returns from Android settings.
- **Diagnostics** with "Copy diagnostic information":
  - Shows app version, flavour and build mode, Android version, device model, and the state of VPN, DNS, search, AI, app protection, the database and permissions.
  - Only whitelisted fields are shown, and every value is reduced to a token. A test proves that domains, queries, PIN and free text can't pass.
- **Help** (troubleshooting and FAQ), **About** (build, attributions, open-source licences including the font OFL and list attribution), **Privacy** (what is stored, what isn't, controls), **Categories** (honest per-category coverage).
- **Release configuration:** `dev` / `staging` / `prod` flavours (default `prod`, so plain `flutter run` keeps working), a flavour-specific app name, and `AppInfo` (version checked against pubspec by a test). R8, signing and log stripping came in Phase 6.
- Native: `diagnostics()`, battery-optimisation status and settings link, and a network-settings link for Private DNS.

## 3. Tests actually executed (in the development container)

| Suite | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` | **178 passed**, 0 failed (was 157 before Phase 7): new `i18n_test` (5), `phase7_test` (16), and updated flow/layout tests. Layout test covers 5 screen sizes incl. 320×568 at 1.3× text, for all screens incl. the new ones |
| Kotlin engine tests (JVM harness) | **239 passed**, 0 failed (was 236): new `Phase7Test` (3) |
| Android layer compile check (against android-all 16) | Compiles |
| JVM benchmarks | Re-run; numbers in `PERFORMANCE.md` |

## 4. Tests NOT executed

- **Any real-device test of Phase 6 or 7.** The only device results are
  D1–D3 on the Phase 5 debug build (see `TEST_MATRIX.md`).
- **`flutter build appbundle --release`** and running a release build:
  the environment has no Android SDK. R8, flavours, `resValues` and
  signing are **unverified**.
- Robolectric SQLite tests (`./gradlew test`): same reason.
- Phone performance: startup, memory, CPU, battery and DNS latency are
  not measured.
- VPN race fixes B3, B4 and B6: Android-only code paths, checked by
  compilation and review only.

## 5. Known limitations

- DNS-level filtering only. Encrypted DNS inside apps or browsers, another
  VPN, and Android settings can get around it. In-app content
  (Instagram/TikTok posts) can't be filtered.
- No large domain lists for violence, gore or dangerous content.
- The text model is small, with limited accuracy. There is no image model.
- The device owner can always disconnect the VPN, clear data or
  uninstall (no device-owner mode, by design).
- Always-on VPN state isn't readable by apps, so it stays a recommendation.
- No notifications: interruptions are shown when the app is opened.
- The `applicationId` is still the placeholder `com.safeguard.app`.

## 6. Remaining risks

- **Release build** may fail or misbehave under R8 or with flavours until
  it's built once. This is the first thing to run.
- **OEM battery managers** (the tester's Infinix/XOS in particular) may
  stop the VPN in the background. The setup assistant recommends an
  exemption, but this is untested.
- **Play review** of the VpnService and Accessibility declarations
  (`GOOGLE_PLAY.md`); the accessibility video is still to be recorded.
- **Bundled lists** are automatically compiled and may block harmless
  sites (the allowlist is the mitigation).
- No fuzzing of the DNS parser has been done.

## 7. Documents added

`GOOGLE_PLAY.md` · `STORE_LISTING.md` · `TEST_MATRIX.md` ·
`PERFORMANCE.md` · `UPDATE_ARCHITECTURE.md` · `THREAT_MODEL.md` ·
`RELEASE_CHECKLIST.md` · `RELEASE.md` (flavours, release tracks) · this
report.
