# Real-device test matrix

**Status values:**
- **PASS / FAIL:** executed on a real device and observed.
- **BLOCKED:** can't be executed yet; the reason is given.
- **N/A:** doesn't apply.
- **NOT EXECUTED:** not run on a device yet.

Automated tests (JVM/widget) are listed separately in the last column. They
are **not** device results.

The only real-device results so far come from the project owner on
2026-09-23 (docs/DEVICE_TEST_LOG.md). They were run on an **Infinix
X6528, Android 13 (API 33), debug build** of commit `ea835db` (Phase 5).
**Nothing from Phases 6–8 has been run on a device.**

## Devices to cover

| Device | Android | Build | Status |
|---|---|---|---|
| Infinix X6528 (XOS) | 13 (API 33) | debug, Phase 5 | Partially tested (rows marked PASS) |
| Pixel or other near-stock device | 14–15 | release (prod flavour) | NOT EXECUTED |
| Samsung (One UI) | 13–14 | release | NOT EXECUTED |
| Android 7–9 device (minSdk 24) | 7.0–9 | release | NOT EXECUTED |
| Android 16 device | 16 | release | NOT EXECUTED |

## Matrix

| # | Area | Case | Expected | Device result | Automated coverage |
|---|---|---|---|---|---|
| M1 | Install | Debug build installs and runs | App opens | **PASS** (Infinix, D1) | — |
| M2 | Install | Release AAB/APK (R8) installs and runs, every screen opens | No crash, no missing classes | NOT EXECUTED | `layout_test` (widgets only) |
| M3 | Onboarding | 8 pages → PIN → wizard → Home | Flow completes | NOT EXECUTED | `app_flow_test`, `phase7_test` |
| M4 | PIN | Wrong PIN, lockout, app restart keeps lockout | Lockout grows, survives restart | NOT EXECUTED | `pin_test` |
| M5 | PIN | Change the clock during lockout; reboot during lockout | Lockout not shortened | NOT EXECUTED | `pin_test` (monotonic fake) |
| M6 | VPN | System consent dialog, then protection active | "Protection is active" | NOT EXECUTED on Phase 7 build | `app_flow_test` |
| M7 | DNS | Domain from the custom blocklist | Blocked page / no connection | **PASS** (Infinix, D3) | `engine_integration_test`, `RuleEngineTest` |
| M8 | DNS | Known gambling site from the bundled list | Blocked | NOT EXECUTED (D4 was before the lists existed) | `BundledListsTest` |
| M9 | Search | Explicit search with protection on / off | SafeSearch results on; unfiltered off | **PASS** (Infinix, D2) | `SearchProtectionTest` |
| M10 | Search | Arabic query, English query, mixed Arabic/English in SafeGuard search | Blocked when it matches rules/keywords/model | NOT EXECUTED | `SearchProtectionTest`, `AiClassifierTest` |
| M11 | Apps | Protect an app, open it, relaunch within 1.5 s | Home + "protected app" screen each time | NOT EXECUTED | `SafeSearchAndAppsTest` (logic only) |
| M12 | Apps | Accessibility off / revoked | App protection reported off; DNS keeps working | NOT EXECUTED | `phase7_test` (setup assistant) |
| M13 | AI | Search text classification | Result within thresholds | NOT EXECUTED | `AiClassifierTest` |
| M14 | AI | Model missing / corrupted | Rules keep working; AI layer "degraded" | NOT EXECUTED | `AiClassifierTest` (hash mismatch) |
| M15 | Modes | Normal ↔ Strict ↔ Custom | PIN rules; categories locked in presets | NOT EXECUTED | `phase5_test` |
| M16 | Lists | Allowlist exact vs subdomains | As configured | NOT EXECUTED | `phase5_test`, `Phase5Test` |
| M17 | Network | Wi-Fi → mobile data → Wi-Fi while browsing | Filtering continues, no lost DNS | NOT EXECUTED | — |
| M18 | Network | Airplane mode on/off | Blocked stays blocked; allowed resumes | NOT EXECUTED | — |
| M19 | Network | Upstream DNS unreachable | "Partially protected", Safe Mode offered | NOT EXECUTED | `Phase5Test` (health) |
| M20 | VPN conflict | Start another VPN app | SafeGuard stops, shows "another VPN", incident recorded, doesn't fight | NOT EXECUTED | `Phase5Test` (incident logic) |
| M21 | Private DNS | Set Private DNS to a hostname | Warning + setup assistant item | NOT EXECUTED | `phase7_test` (checks) |
| M22 | Battery | Battery optimisation on (XOS / One UI), leave phone 1 h locked | Protection still running | NOT EXECUTED | — |
| M23 | Reboot | Reboot with protection on, Always-on off | Starts, or "couldn't start" shown honestly | NOT EXECUTED | — |
| M24 | Reboot | Reboot with Always-on VPN on | Starts before unlock | NOT EXECUTED | — |
| M25 | Lifecycle | Screen lock/unlock, background/foreground, app swipe-away | VPN keeps running; app lock after 30 s | NOT EXECUTED | `app_flow_test` (lock) |
| M26 | Lifecycle | Force-stop from Android settings | Protection off; interruption shown on next open | NOT EXECUTED | — |
| M27 | Safe Mode | Enter Safe Mode, reopen app, reboot | Stays off until re-enabled (Phase 7 fix) | NOT EXECUTED | `phase7_test` |
| M28 | Input | Malformed domains, 5,000-char input, emoji, RTL marks | Rejected cleanly, no crash | NOT EXECUTED | `Phase5Test`, `phase3_test`, `DomainNameTest` |
| M29 | Language | Switch Arabic ↔ English on every screen | Text and direction switch | NOT EXECUTED | `i18n_test` |
| M30 | False positives | Report from block screen and AI result | Counted locally | NOT EXECUTED | `phase4_test` |
| M31 | Database | Corrupt `safeguard.db` (adb, debuggable build) and reopen | App starts; lists keep blocking; DB rebuilt | NOT EXECUTED | `Phase7Test` (lookup failure path) |
| M32 | Storage | Device storage full while browsing blocked sites | No crash; log writes fail silently (diagnostics count) | NOT EXECUTED | `Phase7Test` (log failure) |
| M33 | Memory | Low-memory device / background kill | Service restarts (sticky) or reported | NOT EXECUTED | — |
| M34 | Privacy | Log retention 7 d / none; clear log; delete all data | Data removed | NOT EXECUTED | `phase6_test`, `Phase6Test` |
| M35 | Diagnostics | Copy diagnostic information | No domains/queries/app names | NOT EXECUTED | `phase7_test` |
| M36 | Instagram / TikTok | In-app content | Not filterable (documented) | **N/A** (limitation, D5) | — |
| M38 | Alerts | Allow notifications; start another VPN | "Protection stopped" notification, generic text | NOT EXECUTED | `HealthMonitorTest`, `phase8_test` (PIN to turn off) |
| M39 | Monitor | Break AI model / DB (debug build) while VPN runs | Repaired with backoff, or reported; no loop | NOT EXECUTED | `HealthMonitorTest` |
| M40 | Monitor | Leave phone idle 8 h with VPN on | Battery impact negligible (Doze); no wakeups from SafeGuard | NOT EXECUTED | — |
| M41 | Explanations | Block by list / user rule / keyword / AI | Correct reason on block screen and log | NOT EXECUTED | `Phase8Test`, `phase8_test` (parity) |
| M42 | Feedback | Each report type, with and without diagnostics | Preview == copied/saved text; no domains | NOT EXECUTED | `phase8_test` |
| M43 | Crash reports | Force a crash (debug) → Analytics and reports | Record with type + frames, no message | NOT EXECUTED | `phase8_test` |
| M44 | Backup restore | Corrupt DB (debug) with user lists | Lists, keywords, apps restored | NOT EXECUTED | `UserConfigBackupTest`; `MigrationTest` (CI) |
| M45 | Upgrade | Install 1.6.0, add rules, update to 1.7.0 | Rules, keywords, settings kept | NOT EXECUTED | `MigrationTest` (CI, v1→v4) |
| M46 | AI Content Shield | Every scenario in docs/FINAL_AI_TESTING.md (A1–X1, B1–B18) | As listed there | NOT EXECUTED | `ContentShieldTest`, `ShieldPolicyTest`, `ShieldTextEvalTest`, `ShieldSourceAuditTest`, `content_shield_test` |
| M37 | Robolectric | `cd android && ./gradlew test` | SQLite store tests pass | Not a device test: runs on GitHub Actions (`testProdDebugUnitTest`), green since Phase 8; not runnable in this environment (no Android SDK) | CI |

## Recording a run

Add a dated section to `DEVICE_TEST_LOG.md` for each run, recording the
device, Android version, build (flavour + commit), each row ID and its
result, and for FAIL a copy of **Settings → Diagnostics → Copy**. Never
mark a row PASS from memory or by assumption.
