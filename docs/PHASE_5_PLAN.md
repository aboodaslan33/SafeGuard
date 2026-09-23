# Phase 5 — Implementation plan (written before code changes)

Baseline before any change: `flutter analyze` clean, `flutter test` 114/114,
Kotlin JVM tests 173/173, Android layer compiles. No device, no Android SDK.

## What already exists (reused, not rebuilt)

| Spec item | Existing piece | Phase 5 change |
|---|---|---|
| Blocklist / allowlist | `RuleEngine` USER rules, `DomainRulesScreen`, `DomainName` validation | CUSTOM category; duplicates/conflicts reported instead of silently replaced; allowlist gets an explicit *exact vs. subdomains* scope (DB v4) |
| Boot | `BootReceiver` (boot + app update) | honours Safe Mode, records the outcome so the UI shows the truth |
| Other VPN | `NetworkMonitor.otherVpnActive`, `EngineWarnings` | reused as-is; shown in health |
| Network changes | `NetworkMonitor` + `onUpstreamChanged` | unchanged; DNS upstream failure counters added |
| Modes | Phase 4 AI `DetectionMode` | new global `ProtectionMode` drives categories, search, SafeSearch, AI |
| Events | `BlockEvent` (timestamp, source, category, action, confidence, ruleType) | statistics count only `action = block`; MANUAL events for temporary unlock |
| PIN for loosening | `requirePin` at each call site | central `ProtectionGuard` + Protection Lock + Temporary Unlock |

## New pieces

Pure Kotlin (JVM-tested) under `engine/`:

- `modes/ProtectionModes` — resolves NORMAL / STRICT / CUSTOM into the
  effective categories, search switch, SafeSearch, lexicon threshold, AI.
- `health/ProtectionHealthEvaluator` — layer states (VPN, DNS, rules,
  search, AI, apps, database, permissions) → PROTECTED /
  PARTIALLY_PROTECTED / NOT_PROTECTED.
- `health/RecoveryPolicy` — when a restart may be attempted (never over
  another VPN, never without consent, never in Safe Mode or pause), with
  bounded exponential backoff.
- `health/IncidentDetector` + incident log — tamper/interruption events.
- `pause/TemporaryUnlock` — timed pause, 5/10/30 min, checked against wall
  clock *and* elapsed-realtime so setting the clock back can't extend it.
- `search/CustomKeywords` — validated, normalised, whole-token user keywords.

Android: DB v4 (`include_subdomains`, `custom_keywords`), config for mode /
pause / safe mode / incidents / boot outcome, recovery in the VPN service,
health + statistics + export channel methods.

Flutter: `ProtectionMode` in `ProtectionState`, Protection Lock setting,
`ProtectionGuard`, temporary unlock UI with countdown, health dashboard on
Home, interruption banner, Safe Mode, keywords screen, statistics screen,
privacy controls (clear logs, delete data, reset protection, export).

## Decisions

- Every install starts in **CUSTOM** with all categories on (existing
  installs keep their settings). This is at least as protective as NORMAL
  and keeps Phase 1–4 behaviour; NORMAL/STRICT are opt-in presets.
  *(Changed during implementation: defaulting to NORMAL locked the Phase 1
  category toggles by default and broke 11 existing tests.)*
- NORMAL/STRICT are presets (all categories, search protection, SafeSearch,
  AI on). CUSTOM uses the user's own settings. Lists, keywords and
  protected apps apply in every mode.
- Mode changes need the PIN except NORMAL → STRICT.
- Protection Lock on: every protection change needs the PIN. Off: only
  loosening does (Phase 1–4 behaviour). Turning the lock off needs the PIN.
- Temporary Unlock pauses filtering (VPN stays up; the policy is off until
  the deadline), logs a MANUAL event and resumes by itself — no alarm
  needed because the filter reads the deadline on every query. It does
  **not** relax PIN rules for settings, so a pause can't be used to loosen
  protection permanently.
- Safe Mode is user-invoked (PIN), stops the VPN, blocks every automatic
  restart (boot, always-on, recovery) until the user re-enables protection.
  Suggested automatically when upstream DNS keeps failing. Android's own
  VPN settings remain the last-resort recovery path.
- No notifications (would need POST_NOTIFICATIONS); interruptions are shown
  when the app opens. Documented as a limitation.
