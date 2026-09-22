# Phase 2 — Real Device Test Report

**Date:** 2026-09-22
**Result: real-device validation was NOT performed.** No test in this
report was executed on Android hardware or an emulator.

## Why

The validation was run from a cloud container with:

- **No Android SDK.** `flutter build apk --release` fails with
  `[!] No Android SDK found. Try setting the ANDROID_HOME environment variable.`
  (`flutter doctor`: `✗ Unable to locate Android SDK`).
- **No way to install one.** The SDK, build tools and Google Maven
  (`dl.google.com`; `maven.google.com` redirects there) are denied by the
  environment's organization network policy (proxy: `403 connect_rejected`
  on `dl.google.com:443`). Per instructions, this restriction was not
  worked around.
- **No device.** No USB bus (`/dev/bus/usb` absent), no `adb`, and no
  emulator (requires the SDK and hardware virtualization).

Every row below is therefore **BLOCKED** (could not be run here) or
**NOT TESTED**. No actual result is guessed.

## Device

| Field | Value |
|---|---|
| Device model | — (none available) |
| Android version | — |
| Security patch | — |
| Wi-Fi / Mobile data | — |
| VPN state | — |
| Private DNS state | — |
| Battery optimization state | — |

## 1. Build

| Check | Result | Evidence |
|---|---|---|
| `flutter build apk --release` | **FAIL (environment)** | `No Android SDK found`; exit code 1 |
| Android API compatibility (compile) | PASS (partial) | All Kotlin sources type-check against the Android API 36 framework jar (`org.robolectric:android-all`) and the Flutter embedding jar. APIs above minSdk 24 (`setMetered` 29, `privateDnsServerName` 28) are behind `SDK_INT` guards (manual review; Android Lint not run). |
| APK installation | BLOCKED | No APK, no device |
| App startup | BLOCKED | No device |

## 3. Manual tests (docs/MANUAL_TESTING.md)

| Test | Expected | Actual | Status |
|---|---|---|---|
| Test 1 — Protection OFF, `test1.example.org` | ALLOW | — | BLOCKED |
| Test 2 — Protection ON, `test2.example.org` | BLOCK (NXDOMAIN) + log entry | — | BLOCKED |
| Test 3 — SEXUAL OFF | ALLOW | — | BLOCKED |
| Test 4 — SEXUAL ON | BLOCK | — | BLOCKED |
| Test 5 — Allowlist `example.org` | ALLOW | — | BLOCKED |
| Test 5b — User blocklist, category OFF | BLOCK | — | BLOCKED |
| Test 6 — Wi-Fi → mobile data | VPN stays, filtering continues | — | BLOCKED |
| Test 6b — Mobile data → Wi-Fi | Same | — | BLOCKED |
| Test 6c — Airplane mode | Immediate failure; offline warning; recovers | — | BLOCKED |
| Test 7 — Reboot, Always-on off | Best effort; record outcome | — | BLOCKED |
| Test 7b — Reboot, Always-on on | VPN starts automatically | — | BLOCKED |
| Test 8 — Another VPN starts | Revoked; warning; no fight-back | — | BLOCKED |
| Test 9 — Disconnect in system settings | REVOKED; restart after consent | — | BLOCKED |
| Test 10 — Deny consent | Snack; nothing started | — | BLOCKED |
| Test 11 — Screen off 30 min | Still blocks; low battery use | — | BLOCKED |
| Test 12 — Swipe app away | Still blocks | — | BLOCKED |
| Test 13 — Private DNS `dns.google` | Warning; filtering bypassed | — | BLOCKED |
| Test 14 — Erase all data | VPN stops; data cleared; onboarding | — | BLOCKED |
| Test 15 — Statistics match log | Counts consistent | — | BLOCKED |

## 4–11. Focused checks

| Area | Item | Status | Note |
|---|---|---|---|
| Core VPN | Permission, start, stop, reconnect, network changes, disconnect, restart | BLOCKED | Needs device |
| DNS | Blocked / allowed / subdomain / unknown / malformed / allowlist / blocklist / category on-off | BLOCKED on device | Logic covered by JVM tests (below), not by a device |
| Bypass | Chrome Secure DNS | NOT TESTED | Needs device + Chrome |
| Bypass | Android Private DNS | NOT TESTED | Needs device |
| Bypass | VPN conflict | NOT TESTED | Needs device + second VPN app |
| Bypass | IPv4 / IPv6 | NOT TESTED | Needs a real network |
| Bypass | DNS unavailable | NOT TESTED | Needs device |
| Background | Lock screen, background, other app, wait, return | BLOCKED | Needs device |
| Reboot | Automatic recovery | BLOCKED | **Not claimed.** Unknown until tested |
| Battery | OEM battery optimization impact | NOT TESTED | Needs specific OEM devices |
| Database | Add/remove rule, categories, lists, stats, logs, persistence after restart | BLOCKED on device | SQL verified against real SQLite (desktop), not Android's SQLite |
| PIN | Correct / wrong / repeated / allowlist / settings lock / app restart | BLOCKED on device | Covered by Flutter tests with in-memory storage, not Keystore |
| PIN | Device restart | BLOCKED | |
| PIN | Clock change | NOT TESTED | Known limitation: lockout uses the wall clock |

## 12. Stress test (JVM only)

`DnsFilterTest.randomGarbageNeverThrows`: 20,000 random buffers plus
20,000 random DNS payloads in valid IPv4/UDP envelopes, all through
`DnsPacketFilter.process`. **PASS**, no exception. This proves only that
the packet parser is robust against malformed input. It says nothing about
the VPN service, threading, battery or real traffic. Device stress: BLOCKED.

## 13. SQLite

- Robolectric `SqliteStoresTest`: **not run** (needs `androidx.test` from
  Google Maven; not worked around).
- Every SQL statement executed against desktop SQLite 3.45 with
  assertions: **PASS** (Phase 2 session). The statements avoid syntax newer
  than Android 7's SQLite, but this was checked by review, not on Android.
- Real-device SQLite validation: **not done**.

## Automated tests actually run in this session

| Suite | Result |
|---|---|
| `flutter analyze` | PASS, no issues |
| `flutter test` | PASS, 73/73 |
| Kotlin engine JUnit (JVM harness) | PASS, 45/45 (43 + 2 new regression tests) |
| Kotlin Android layer compile check | PASS |

## Bugs found and fixed in this session (by code review, not on a device)

The device tests below would have hit these bugs. Each fix is covered by
a new JVM test where the logic is pure Kotlin. The service-level parts are
compile-checked only.

| # | Bug | Impact | Fix | Verified by |
|---|---|---|---|---|
| B1 | `shutdown()` always set STOPPING, and `onDestroy` calls it a second time after revoke, stop, start errors and missing consent. That overwrote the final state. | Tests 8/9/10: after another VPN takes over, the dashboard would stay on "جارٍ تشغيل الحماية" with no restart button, and error and consent states were lost. | `ProtectionStatusHolder.stopping()` only applies to a STARTING/RUNNING VPN. | `stoppingOnlyAppliesToALiveVpn` (JVM) |
| B2 | Tun poll loop `continue`d on POLLERR/POLLHUP/POLLNVAL, and any unexpected loop exit left the status RUNNING with the tun still up. | Possible 100% CPU spin, or all DNS black-holed (no internet) while the UI showed "active". | Break on error events. On any unrequested exit, report ERROR and tear the VPN down so DNS falls back to the network. | Compile check only; **needs device test** |
| B3 | Every status refresh from Flutter reset `upstreamAvailable` to false while the VPN ran. | False "لا يوجد اتصال بالشبكة" warning whenever the dashboard refreshed (tests 6/6c). | Network facts come only from the VPN's network monitor (`upstreamChanged`) and are cleared when the VPN stops. `refreshEnvironment()` only re-checks for another VPN. | `environmentRefreshKeepsUpstreamFacts` (JVM) |

No documented behaviour was changed. These fixes make the implementation
match what `docs/ARCHITECTURE.md` already described.

## Totals (manual tests 1–15, including sub-cases)

| | Count |
|---|---|
| Total PASS | 0 |
| Total FAIL | 0 |
| Total BLOCKED | 19 |
| Total NOT TESTED | 0 |

Focused checks (sections 4–11): 0 PASS, 0 FAIL, 7 BLOCKED, 7 NOT TESTED.

## To complete this report

On a machine with the Android SDK and a real device (USB debugging on):

```bash
flutter build apk --release   # uses the debug signing config for now
flutter install               # or: adb install build/app/outputs/flutter-apk/app-release.apk
flutter build apk --debug     # debug build seeds the example.org / example.net test rules
cd android && ./gradlew test  # 45 engine tests + Robolectric SQLite tests
adb logcat -s SafeGuardVpn
```

Then fill in the Device table and the Actual/Status columns above,
following `docs/MANUAL_TESTING.md`. Tests 2–5 need a **debug** build (test
rules are not seeded in release builds).
