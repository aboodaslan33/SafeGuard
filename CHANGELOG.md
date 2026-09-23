# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). Versioning:
[SemVer](https://semver.org/). `MAJOR.MINOR.PATCH+build`, where `build` is
the Android `versionCode` and always increases.

Every release lists **Migration notes** (data / settings changes),
**Security notes** when relevant, and a **Rollback** strategy. On Google
Play a rollback is always a *new* release with a higher `versionCode`
carrying the previous code (see docs/RELEASE.md).

## [1.9.0+10] — AI Content Shield: image AI, screen capture, skip

### Added
- **On-device image AI:** GantMan nsfw_model v1.1.0 MobileNetV2
  (official `saved_model.tflite`, unmodified, MIT, 24.4 MB), pinned by
  size and SHA-256 and run with LiteRT. porn/hentai → SEXUAL; sexy →
  SUGGESTIVE (blocked in STRICT); drawings/neutral → SAFE.
- **Image checks** through MediaProjection: Android's consent dialog,
  capture indicator, foreground notification; frames only while a
  supported app is in front; never saved or sent. PIN to stop.
- **Skip action:** blocked content is swiped past (next reel/short/post),
  then Back, then Home with the blocking screen.
- **Facebook** and Facebook Lite in the supported apps.

### Security notes
- New permissions `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`
  (used only after the user's consent). The accessibility service gains
  `canPerformGestures` for the single skip swipe.
- The image model's training data was web-scraped; provenance accepted by
  the project owner (docs/AI_CONTENT_SHIELD.md §4).

### Migration notes
- No database change. Rule type of shield events gains the action
  (`…:<skip|back|home>`); older entries still parse.

### Rollback
- Release 1.8.0 code as a higher `versionCode`; capture stops with the
  old build (it has no capture service).

## [1.8.0+9] — Final AI phase: AI Content Shield

### Added
- **AI Content Shield** (optional, off by default): on-device checking of
  text shown in supported apps (Instagram, TikTok, YouTube, Reddit,
  Chrome, Firefox) through a separate, package-restricted accessibility
  service. The existing policy engine decides; a block sends the user home
  and shows the "content blocked" screen (category only).
- AI labels SAFE, SUGGESTIVE, SEXUAL, NUDITY, VIOLENCE, GORE, GAMBLING,
  DRUGS, DANGEROUS, UNKNOWN; every result carries label, model confidence
  and model version. SUGGESTIVE counts only in STRICT mode.
- Temporal confirmation (one uncertain sample never blocks), sampling
  gate, inference watchdog, separate text budget.
- Image pipeline and model-pack format (`sg-image-pack/1`, SHA-256
  pinned). **No image model is bundled** and no runtime is compiled in:
  image/video checks are unavailable and the UI says so.
- AI Content Shield screen: real state (never "active" without image AI),
  model status, supported apps with limitations and "not tested on a
  device yet", categories and mode, privacy summary. PIN to turn it or an
  app off.
- docs/AI_CONTENT_SHIELD.md (model evaluation, measurements, limits),
  docs/FINAL_AI_TESTING.md (manual plan, not executed).

### Changed
- The AI protection screen links to the shield and no longer says AI
  never looks at other apps.

### Migration notes
- No database change (shield blocks use the existing event columns; rule
  type `ai_shield:<kind>:<label>:<model>`). New preferences
  `shield_enabled` (default false), `shield_disabled_apps`,
  `shield_disclosure_declined`.

### Security notes
- New accessibility service with window-content access, limited to six
  package ids at the system level; no new permission. Input and password
  fields are never read; no storage, logging, network, screenshots or
  overlays in the shield path (enforced by `ShieldSourceAuditTest`).

### Rollback
- Release 1.7.0 code as a higher `versionCode`. The shield preferences are
  ignored by 1.7.0; Android keeps the unused accessibility entry until the
  app no longer declares it (it disappears with the rollback build).

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
- Statistics used `java.time` (API 26+) and would crash on Android 7.0/7.1;
  now uses `java.util.Calendar` (found by lint on the first CI build).
- The "protected app" screen handles the Android 16 predictive back
  gesture (goes home instead of just closing).

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
