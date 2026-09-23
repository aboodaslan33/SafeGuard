# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). Versioning:
[SemVer](https://semver.org/). `MAJOR.MINOR.PATCH+build`, where `build` is
the Android `versionCode` and always increases.

Every release lists **Migration notes** (data / settings changes),
**Security notes** when relevant, and a **Rollback** strategy. On Google
Play a rollback is always a *new* release with a higher `versionCode`
carrying the previous code (see docs/RELEASE.md).

## [1.7.0+8] — Phase 8: maintainability, monitoring, updates

### Added
- Continuous health monitor while the VPN runs: checks every 15 min and
  after network changes. It repairs the AI model, the database and the
  bundled lists with exponential backoff (1 → 4 → 16 min … 4 h, at most
  6 attempts a day).
- Optional "protection stopped" notification. It needs notification
  permission on Android 13+ and is off if the user declines. Turning it
  off requires the PIN.
- Unified decision explanations (why something was blocked or allowed),
  shown in the log and on the block screen. A content-free decision trace
  can be turned on in Diagnostics.
- Signed update verifier and store for rules, lists and AI models (ECDSA
  P-256 manifests, version / expiry / compatibility / checksum / full-parse
  checks, atomic activation, rollback, retention). **Not connected to any
  server:** no update transport ships.
- Local crash reports (error type and app stack frames only), which the
  user can view, copy, delete or turn off.
- Opt-in telemetry (**off by default**), local only: daily counts of a
  fixed set of error types.
- Feedback: report a false positive, missed content or a technical
  problem. The user picks the fields and sees an exact preview, then
  copies or saves it. Nothing is sent automatically.
- A plan abstraction (Free / Premium) without billing. Protection is never
  gated.
- A private backup of the user's lists, keywords and protected apps,
  restored if the database is rebuilt.
- CI (GitHub Actions: format, analyze, Flutter tests, Kotlin + Robolectric
  tests, lint, builds, gitleaks), a release workflow using CI secrets, and
  Dependabot.

### Fixed
- Concurrent telemetry and crash writes could lose an update.

### Migration notes
- New SharedPreferences keys: `alerts_enabled` (native, default true);
  `sg.telemetry.*` and `sg.crash.*` (Flutter). No schema change (DB v4).
- New private file `no_backup/user-config.bak`, written on the first
  change to lists, keywords or protected apps.
- New permission: `POST_NOTIFICATIONS` (runtime, optional).

### Security notes
- Decision traces, diagnostics, crash records and feedback all use
  whitelists or sanitisers. Tests check that no domain, query or error
  message can pass.
- Update packages need a signature from a pinned key. No key is pinned in
  this build, so updates can't be activated at all.

### Rollback
- Installing 1.6.0 over 1.7.0 keeps the DB (still v4). The unknown prefs
  keys are ignored and the backup file is unused.

## [1.6.0+7] — Phase 7: beta preparation
### Added
- English (LTR) UI alongside Arabic.
- Onboarding (8 pages), a first-run protection wizard, a setup assistant,
  Diagnostics with copy, and Help / About / Privacy / Categories screens.
- `dev` / `staging` / `prod` flavours.

### Fixed
- Crash on disk-full log writes.
- A SQLite error on the DNS path no longer ends filtering.
- Race between VPN revoke and recovery; the revoke incident is now
  recorded.
- Opening the app ended Safe Mode or a pause.
- An app-protection relaunch bypass.
- Stale rule cache after the lists finished loading.
- Out-of-order status events.
- Futures left pending when the app detached.
- Malformed truncated DNS reply.

### Migration notes
- `ui_language` pref; accessibility strings localised.

### Rollback
- Safe to 1.5.0 (no schema change).

## [1.5.0+6] — Phase 6: security & privacy hardening
### Security
- HMAC key moved to the Android Keystore.
- PIN lockout uses a monotonic clock.
- Log messages are constant.
- R8, and signing from `key.properties`.

### Added
- Log retention (7 / 30 days / none).

### Migration notes
- The legacy `event_hash_key` pref is deleted on first start. Search-event
  ids from before the update don't correlate with new ones.

### Rollback
- No schema change (DB v4): 1.4.0 can be installed over it. The Keystore
  HMAC key is simply unused by 1.4.0 (it regenerates its own pref key).

## [1.4.0+5] — Phase 5 and bundled lists
- Modes, health, recovery, Protection Lock, pause, Safe Mode, keywords,
  allowlist scope and statistics.
- Bundled gambling, sexual and drugs domain lists.
- DB v4.

## [1.3.0+4] — Phase 4
- On-device text classifier, image pipeline and the AI decision engine.
- DB v3.

## [1.2.0+3] — Phase 3
- Search protection (SafeSearch, lexicon) and app protection.
- DB v2.

## [1.1.0+2] — Phase 2
- Local VPN and DNS filtering, rules, logging, statistics.
- DB v1.

## [1.0.0+1] — Phase 1
- Foundation: design system, Arabic RTL UI, PIN.
