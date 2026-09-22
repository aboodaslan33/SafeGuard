# Manual Android Testing — Phase 2

## Status: NOT EXECUTED

These tests have **not been run on a real device or emulator**. The
development environment had no Android SDK (its download host,
`dl.google.com`, was blocked by the network policy), so no APK could be
built or installed. No result below is claimed; each row has the expected
result and an empty "Actual" column to fill in.

What *was* verified without a device:

- Kotlin engine: 45 JUnit tests (DNS parsing incl. fuzzing, IPv4/UDP
  checksums, rule precedence, subdomains, false positives, malformed input,
  logging, statistics, status transitions) — all pass on the JVM.
- The full Android layer (VpnService, SQLite stores, channel, boot receiver,
  MainActivity) type-checks against the Android API 36 framework jar.
- Every SQL statement was executed against real SQLite.
- Flutter: 73 widget/unit tests incl. the platform-channel contract.

Latest attempt and results: [`PHASE_2_REAL_DEVICE_TEST.md`](PHASE_2_REAL_DEVICE_TEST.md).

## Setup

1. Build a **debug** APK (`flutter run` or `flutter build apk --debug`).
   Debug builds seed test rules; release builds do not:

   | Domain | Category | Action |
   |---|---|---|
   | `example.org` (+ subdomains) | SEXUAL | BLOCK |
   | `example.net` | GAMBLING | BLOCK |
   | `example.com` | SAFE | ALLOW |

2. In Android Settings → Network → Private DNS, choose **Off** or
   **Automatic** (a named provider bypasses SafeGuard by design).
3. Use a browser *without* its own secure-DNS setting, or turn that setting
   off (Chrome: Settings → Privacy → Use secure DNS). Otherwise the browser
   bypasses system DNS.
4. Helpful commands:

   ```bash
   adb shell ping -c 1 example.org      # blocked → "unknown host"
   adb shell ping -c 1 example.com      # allowed → resolves
   adb logcat -s SafeGuardVpn
   ```

   Note that Android and browsers cache DNS answers for a while. After
   changing a setting, wait ~1 minute or use a fresh subdomain
   (e.g. `test1.example.org`) to avoid stale results.

## Test cases

| # | Steps | Expected | Actual |
|---|---|---|---|
| 1 | Protection OFF. Open `http://test1.example.org`. | ALLOW: page loads. | |
| 2 | Protection ON (consent granted). Open `http://test2.example.org`. | BLOCK: browser shows "site can't be reached" (NXDOMAIN). Entry appears in سجل الحظر with category المحتوى الجنسي. | |
| 3 | Category المحتوى الجنسي OFF (PIN). Open `test3.example.org`. | ALLOW. | |
| 4 | Category المحتوى الجنسي ON. Open `test4.example.org`. | BLOCK. | |
| 5 | Settings → النطاقات المسموحة (PIN) → add `example.org`. Open `test5.example.org`. | ALLOW, despite SEXUAL rule. | |
| 5b | Blocklist: add `wikipedia.org` (category any). Open `en.wikipedia.org`. | BLOCK even if that category is OFF. | |
| 6 | Protection ON, on Wi-Fi. Turn Wi-Fi off (mobile data on). Open `test6.example.org` and `example.com`. | VPN key icon stays; blocked stays blocked; allowed resolves on mobile data. | |
| 6b | Mobile data → Wi-Fi. Repeat. | Same. | |
| 6c | Airplane mode on. Open `test7.example.org`. | Fails immediately (blocked or offline). Dashboard warns about no network. Airplane mode off → allowed sites work again. | |
| 7 | Reboot with Always-on VPN **off**. | Best effort: BootReceiver restarts the VPN if consent exists; some OEMs block this → dashboard shows "الحماية غير نشطة". Record which happened. | |
| 7b | Enable Settings → VPN → SafeGuard → Always-on VPN. Reboot. | VPN starts by itself after boot. | |
| 8 | Start another VPN app while SafeGuard runs. | SafeGuard receives `onRevoke`; dashboard: "الحماية غير نشطة" + other-VPN warning. SafeGuard does not restart itself over the other VPN. | |
| 9 | Disconnect SafeGuard from the system VPN settings. | Status REVOKED; "تشغيل الحماية" restarts it after consent. | |
| 10 | Deny the consent dialog. | Snack "لم تُمنح موافقة VPN"; protection inactive; nothing started. | |
| 11 | Screen off 30 min, screen on. Open a blocked domain. | Still blocked; no noticeable battery use by SafeGuard in battery stats. | |
| 12 | Swipe SafeGuard away from recents. Open a blocked domain. | Still blocked. | |
| 13 | Private DNS set to `dns.google`. | Dashboard shows the Private DNS warning; blocking not effective (documented limitation). | |
| 14 | Settings → حذف جميع البيانات (PIN). | VPN stops, native rules/logs cleared, app returns to onboarding. | |
| 15 | Status tab after tests 2–6. | Today / last 7 days / total and per-category counts match the log. | |
