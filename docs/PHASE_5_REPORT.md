# Phase 5 — Advanced Protection: Report

Plan written before implementation: [`PHASE_5_PLAN.md`](PHASE_5_PLAN.md).

**Status:** implemented and tested automatically. **Not built as an APK and
not run on an Android device** (no Android SDK in this environment; Google
Maven is blocked). Nothing below that needs a device is claimed as
working on one.

## 1. Deliverables

| Deliverable | Implementation | Where |
|---|---|---|
| Protection modes NORMAL / STRICT / CUSTOM | `ProtectionModes.resolve` turns the mode into the enforced categories, SafeSearch, search-lexicon threshold (0.60 / 0.45) and AI mode. Presets lock the settings they own; CUSTOM uses the user's own. Mode travels with the policy to native. | `engine/modes/`, `ProtectionConfigStore`, Home |
| Health monitoring | `ProtectionHealthEvaluator`: VPN, DNS, rules, search, AI, apps, database, permissions → PROTECTED / PARTIALLY_PROTECTED / NOT_PROTECTED with a reason id. Shown on Home ("لوحة الحماية") and the status card (new "partial" and "suspended" states — never "active" when it isn't). | `engine/health/ProtectionHealth.kt`, `ProtectionManager.health()` |
| Automatic recovery | `RecoveryPolicy`: restart only if the user wants protection, no pause/Safe Mode, consent present, no other VPN, state ERROR/STOPPED; ≤ 3 attempts per 10 min, 1 s / 4 s / 16 s. Used when the filter loop crashes (in the service) and when the app returns to the foreground. A failed recovery is reported, not hidden. | `engine/health/Recovery.kt`, `SafeGuardVpnService`, `ProtectionManager.tryRecover()` |
| Boot handling | `BootReceiver` (boot + app update): settings → consent → start; records the outcome (`disabled`, `safe_mode`, `permission_required`, `start_requested`, `blocked`) and an incident when it can't start. | `vpn/BootReceiver.kt` |
| Custom blocklist | Category **مخصص** (`custom`) or any content category; validation + normalisation (scheme/path/`www.`/case/IDN); duplicates and cross-list conflicts refused; subdomains always covered; applies whatever the category toggles. | `engine/rules/UserRules.kt`, `RuleEngine`, rules screen |
| Allowlist | Explicit scope: **exact** (domain + `www.`, default) or **with all subdomains** (user must switch it on, explained in the form). Existing Phase 2 entries keep covering subdomains (DB default 1). | `Rule.includeSubdomains`, DB v4 |
| Custom keywords | Whole words/phrases only, ≥ 3 letters, ≤ 5 words, not digits-only, normalised (Arabic unification, case), max 500; pipeline **keywords → built-in lexicon → AI → decision engine**. | `engine/search/CustomKeywords.kt`, `AiSearchFilterService`, Keywords screen |
| Protection Lock | When on, every change to categories, mode, thresholds, allowlist, blocklist, keywords, search and AI settings needs the PIN (tightening too). Turning the lock off needs the PIN. | `ProtectionGuard`, `AppSettings.protectionLocked` |
| Temporary unlock | 5 / 10 / 30 min, PIN, countdown, MANUAL event, automatic resume. Anchored to wall clock **and** elapsed-realtime: moving the clock back or rebooting can only end it early. The VPN stays up; the filter reads the deadline per query, so resume needs no alarm. | `engine/pause/TemporaryUnlock.kt` |
| Tamper / interruption detection | VPN revoked, filter failed, consent withdrawn, accessibility switched off (with protected apps), boot start refused → stored incidents → "انقطعت الحماية" banner with "أعد تفعيل الحماية". User-initiated stops are not incidents. | `IncidentDetector`, `IncidentLog`, Home |
| Safe Mode | PIN + explanation; stops the VPN; blocks every automatic restart (boot, Always-on, sticky, recovery) until the user re-enables protection. Suggested when upstream DNS keeps failing (health reason `upstream_failing`). | `ProtectionManager.enterSafeMode()`, Settings |
| Advanced dashboard | Home: status card, interruption banner, warnings, dashboard (overall, mode, VPN, DNS, search, AI, protected apps, blocked today), mode selector, categories. | `home_screen.dart`, `protection_dashboard.dart` |
| Statistics | Today / 7 days / 30 days: total, domains (DNS), searches, AI blocks, protected-app openings, category distribution incl. custom, false-positive reports. Only `action = block` is counted (the temporary-unlock events are not blocks). | `StatisticsService.detailed()`, Statistics screen |
| Privacy controls | Clear protection logs (PIN), delete all data (PIN, existing), reset protection (PIN; lists/keywords/apps/logs kept), export settings (PIN; JSON via the system save dialog). | `AdvancedActions`, `SettingsExport` |

Unified event model (unchanged from Phase 3, extended): `timestamp, source
(DNS/SEARCH/APP/AI/MANUAL), category, action, confidence, ruleType` plus a
non-sensitive subject. No content is stored.

## 2. Tests

| Suite | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` | **142/142** (114 existing + 28 new in `test/features/phase5_test.dart`) |
| Kotlin JVM tests (same sources `./gradlew test` would run) | **217/217** (173 existing + 44 new: `Phase5Test.kt` 43, `Phase5BenchmarkTest.kt` 1) |
| Android layer compile check (API 36 framework + Flutter embedding) | Pass |
| `cd android && ./gradlew test` | **Fails before running tests**: the Android Gradle Plugin cannot be resolved (Google Maven blocked, no SDK) |
| Robolectric `SqliteStoresTest` (incl. new v4/keywords/statistics test) | **Written, not run** (needs the SDK) |
| DB v1→v4 migration SQL | Run against desktop SQLite 3.45 (not Android's SQLite) |

Existing tests changed (no assertion removed or weakened):
- `engine_integration_test`: the expected `setConfiguration` arguments now
  include `'mode': 'custom'` (the protocol gained a field).
- `app_flow_test`: scrolls to the category list before tapping, because Home
  now has the dashboard above it.
- `LoggingStatusTest` etc. unchanged; statistics now count only blocks —
  all earlier fixtures were blocks, so no earlier expectation changed.

## 3. Security report

| Test area | What was tested | Result |
|---|---|---|
| PIN brute force | Phase 1 escalating lockout (5 free attempts, then 30 s … 1 h, persisted across restarts). New: the temporary-unlock gate hits the same lockout and refuses even the correct PIN while locked (`phase5_test`). | Pass (automated) |
| PIN-gated actions | Mode loosening, lock off, temporary unlock, Safe Mode, reset, export, clear logs, keyword/blocklist removal, allowlist changes; Protection Lock gating tightening too. A pause does **not** relax these rules. | Pass (automated) |
| Invalid / malicious domains | Empty, TLD-only, `localhost`, IPv4/IPv6 literals, spaces, leading hyphen, 64-char labels, > 253 chars, SQL-injection text, `<script>`, empty labels, numeric TLD; IDN converted to punycode. | Rejected (`UserRulesTest`) |
| Malformed rules / keywords | Duplicates, cross-list conflicts, non-assignable categories, list limits, too-short / digits-only / too-long keywords, substring false positives. | Rejected / no match |
| Malformed DNS packets | Phase 2 fuzz test (random garbage never throws) + compression-loop / truncation tests. | Pass (unchanged) |
| Database corruption | Android's default `SQLiteOpenHelper` error handler deletes a corrupt database and recreates it: SafeGuard keeps working, built-in rules are reseeded, **user lists/keywords/logs are lost**. The health report shows DATABASE degraded if queries fail. | Documented; **not executed** |
| Service restart / VPN failure | Recovery policy (never over REVOKED/other VPN/no consent/Safe Mode/pause; bounded backoff) and incident detection unit-tested. Real service restarts: **not executed**. | Logic pass; device not tested |
| Permission removal | VPN consent withdrawn → PERMISSION_REVOKED incident, NOT_PROTECTED, no automatic restart. Accessibility off with protected apps → incident + apps layer inactive. | Logic pass; device not tested |
| Network changes | Existing `NetworkMonitor` (Phase 2) moves the upstream on Wi-Fi ↔ mobile, airplane mode, reconnect; offline keeps blocking and answers SERVFAIL fast. Upstream failure tracking is unit-tested. SIM change / DNS change are ordinary network callbacks. | Not executed on a device |
| Large rule lists | 102 000 rules (see §4). | Pass (JVM) |
| Settings export | Recursive key scan: no PIN/hash/salt/secret/token/log/event fields; user is warned that lists reveal preferences. | Pass (automated) |
| Clock tampering | Temporary unlock can't be extended by moving the clock back or rebooting. | Pass (`TemporaryUnlockTest`) |
| No Android bypasses | No root, no exploits, no disabling other VPNs, no forcing two VPNs, no notification/overlay abuse; the user can always disconnect the VPN or uninstall in system settings. | By design |

## 4. Performance report

Measured on the **build container's JVM** (JDK 21, 4 vCPU, x86-64) by
`Phase5BenchmarkTest`, with a hash-indexed stand-in for the SQLite rule
store. **Not measured on a phone.**

| Measurement | Result |
|---|---|
| Rule set | 102 000 rules; index built in ~50 ms |
| Rule decision, cache miss (distinct deep subdomains) | ~5.4 µs |
| Rule decision, cache hit | ~0.4 µs |
| DNS packet → decision (+ NXDOMAIN reply) in-process, names repeating (mostly cache hits) | ~0.7 µs/query |
| Custom keyword match, 500 keywords | ~7 µs/query |
| Health evaluation (logic only) | ~0.1 µs |
| Statistics: all 9 queries (3 windows × total/source/category) on 10 000 events | ~15.5 ms on **desktop** SQLite 3.45; uses `idx_events_ts` (EXPLAIN QUERY PLAN) |
| AI inference (Phase 4, unchanged) | ~30 µs/query text on JVM; no image model |

**Not measured:** CPU %, RAM of the running app, battery, VPN overhead,
DNS latency end-to-end (it is dominated by the network resolver's round
trip), Android SQLite timings. Design notes (not measurements): the VPN
loop blocks in `poll()` when idle; the pause needs no timer in native;
the countdown timer runs only while the app is open; health is computed on
demand (app open/resume, status changes), not periodically.

## 5. Known Android limitations

- **One VPN at a time.** If another VPN is active SafeGuard says «يوجد VPN آخر نشط» and does not try to disable it or run alongside it.
- **Boot:** a background start after boot may be refused (OEM/battery policies). The reliable path is Android's *Always-on VPN*; the app shows the real state and records a failed boot start.
- **No push alerts** for interruptions (would need the notification permission); they appear when the app is opened. Android's own VPN key icon disappears when the VPN stops.
- **The owner can always** disconnect the VPN, disable the accessibility service, clear data or uninstall from system settings. Without Device Owner mode, SafeGuard can detect and report this, not prevent it.
- **Private DNS / DoH / hard-coded DNS** bypass DNS filtering (reported as partial protection when detected).
- **Recovery** cannot restart a VPN whose consent was withdrawn or that was replaced by another VPN — only the user can.
- **Database corruption** resets local data (see §3).
- **Safe Mode** is manual; SafeGuard never switches protection off by itself. If the app can't be opened, the VPN can still be disconnected in Android settings.
- **Temporary unlock** pauses all filtering layers (DNS, search, AI, app protection) for its duration.
- Presets: NORMAL/STRICT enforce all categories; unknown domains are never blocked, even in STRICT (it would break most of the web).

## 6. Manual tests (to run on a device)

| # | Steps | Expected | Result |
|---|---|---|---|
| P5-1 | Home → mode عادي (PIN) → صارم (no PIN) → عادي (PIN) | PIN only where stated; YouTube restricted mode strict in صارم | NOT EXECUTED |
| P5-2 | In صارم, try a category switch | Disabled, "يحددها الوضع" | NOT EXECUTED |
| P5-3 | Settings → قفل إعدادات الحماية on; enable a disabled category | PIN required | NOT EXECUTED |
| P5-4 | إيقاف مؤقت 5 دقائق (PIN); visit a blocked domain; wait | Loads during pause; blocked again after 5 min without opening the app | NOT EXECUTED |
| P5-5 | Start a 30-min pause, move the system clock back 1 h | Pause still ends 30 real minutes after start | NOT EXECUTED |
| P5-6 | Connect another VPN app | "انقطعت الحماية" + "يوجد VPN آخر نشط"; no fighting | NOT EXECUTED |
| P5-7 | Disconnect SafeGuard in Android VPN settings; reopen app | Banner; "أعد تفعيل الحماية" works | NOT EXECUTED |
| P5-8 | Reboot with protection on (without / with Always-on VPN) | Status shows what really happened | NOT EXECUTED |
| P5-9 | Wi-Fi → mobile → airplane → online | Filtering continues; offline blocks still blocked | NOT EXECUTED |
| P5-10 | Blocklist example.com (مخصص); open www / sub.example.com | Blocked; log shows "مخصص" | NOT EXECUTED |
| P5-11 | Allowlist exact school.test; open sub.school.test in a blocked category | Subdomain still blocked; with "يشمل كل النطاقات الفرعية" allowed | NOT EXECUTED |
| P5-12 | Keyword "glitter" → search "glitter bomb" / "glittering" | First blocked, second not | NOT EXECUTED |
| P5-13 | Safe Mode (PIN) → reboot | VPN stays off until "إعادة تفعيل الحماية" | NOT EXECUTED |
| P5-14 | Export settings → open the file | No PIN, no logs; lists present | NOT EXECUTED |
| P5-15 | Statistics today/7/30 after some blocks | Counts match the log | NOT EXECUTED |
| P5-16 | Upgrade from Phase 4 install | DB v3→v4; old allowlist still covers subdomains; mode CUSTOM | NOT EXECUTED |
| P5-17 | 1 h normal use, battery stats | SafeGuard not a notable consumer | NOT EXECUTED |

Totals: 0 PASS, 0 FAIL, 17 NOT EXECUTED.
