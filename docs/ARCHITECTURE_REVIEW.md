# Architecture review (Phase 8)

Scope: the whole codebase at version 1.6.0: about 22,300 lines of Dart and
Kotlin, excluding tests. The findings come from reading the code, not from
tooling. **Priorities:** P1 = do before scaling features, P2 = next few
releases, P3 = opportunistic. **Migration risk** is the chance of breaking
working protection while fixing the issue.

Stable parts not to rewrite: the pure Kotlin engine (`engine/**`: DNS
parsing, rules, lists, search, AI, health, recovery), which is covered by
239 JVM tests; the PIN subsystem; and the router gate. Most issues below
are around them, not in them.

## Summary

| ID | Area | Issue | Priority | Migration risk | Phase 8 action |
|---|---|---|---|---|---|
| A1 | Coupling | `ProtectionManager` is a 700+ line god object | P1 | Medium | Plan below; new code added as separate collaborators |
| A2 | Coupling | `ProtectionChannel`: 57-case stringly-typed `when` | P2 | Medium | Documented; contract tests stay the guard |
| A3 | Testability | `ProtectionEngine` interface: ~50 methods; every fake implements all | P2 | Low | New features (feedback, telemetry, crash, entitlements) built outside it |
| A4 | Duplication | Categories, thresholds and domain validation defined in both Dart and Kotlin | P2 | Low | Documented; parity test recommended |
| A5 | Testability | Native singletons (`ProtectionManager.get`) need Robolectric; those tests can't run here | P2 | Medium | New native logic written as pure engine classes (updates, monitor policy, trace, explanation) |
| A6 | Tech debt | Robolectric SQLite tests never run in this environment | P1 | — | CI workflow added (runs them on GitHub runners) |
| A7 | Scalability | Rule updates only by app update; bundled lists are 10.6 MB of the APK | P2 | Medium | Signed update verifier + atomic store implemented (no transport) |
| A8 | Security | Bundled lists and model pinned only by in-APK SHA-256; no signature chain for future updates | P2 | Low | ECDSA-signed manifest verification implemented and tested |
| A9 | Reliability | Health was evaluated only on demand (app open) | P1 | Low | Continuous monitor while the VPN runs + degraded notification |
| A10 | Maintainability | i18n via `tr(ar, en)` at call sites, no ARB/translation workflow | P3 | Low | Keep; fine for 2 languages. Move to ARB only if a third language is added |
| A11 | Performance | `recentBlocks` / statistics queries on the channel's single IO thread | P3 | Low | Measured ~15 ms desktop; acceptable; revisit with device numbers |
| A12 | Tech debt | Test fixtures (debug seed rules) live in main source | P3 | Low | Guarded by `FLAG_DEBUGGABLE`; could move to a `debug` source set |
| A13 | Duplication | Explanations of block reasons are scattered (native `DecisionReason`, Dart `ruleType` strings, UI text) | P2 | Low | Unified `DecisionExplanation` codes implemented |
| A14 | Security | The DNS parser hasn't been fuzzed | P2 | Low | CI job recommended (JVM fuzz with Jazzer); not added |
| A15 | Dependencies | 4 runtime Dart packages (`crypto`, `flutter_secure_storage`, `go_router`, `shared_preferences`); no Kotlin runtime deps | — | — | Fine: all maintained, all needed |

---

## Details

### A1: `ProtectionManager` is a god object
- **Problem:** one class owns config, database, rule engine, bundled
  lists, logging, statistics, AI, keywords, app protection, health,
  recovery, incidents, diagnostics and the exempt-package cache.
- **Impact:** every change touches it; it can only be tested through
  Robolectric; and its initialisation order matters (Phase 7 found a
  crash path there).
- **Recommended solution:** extract along existing seams, one at a time,
  each as a plain class the manager composes:
  `RulesService` (store + lists + engine + counts), `LogService`,
  `AiService`, `AppGuard`, `HealthService`. Keep `ProtectionManager` as a
  thin facade so the channel and service don't change.
- **Priority:** P1. **Migration risk:** medium (initialisation order).
  Do it behind the existing JVM tests plus a Robolectric smoke test in CI.

### A2: Stringly-typed platform channel
- **Problem:** method names and map keys are strings on both sides.
- **Impact:** a typo is a runtime `notImplemented`; the contract lives in
  a comment.
- **Solution:** either generate the channel with Pigeon (adds a dev-time
  dependency only) or keep the hand-written channel but add a shared
  contract test that lists every method on both sides (Dart has one for
  some methods).
- **Priority:** P2. **Risk:** medium for Pigeon (large diff), low for the
  contract test.

### A3: Oversized `ProtectionEngine` interface
- **Problem:** about 50 methods covering VPN, rules, logs, search, apps, AI,
  health, keywords, export, diagnostics and language.
- **Impact:** every fake and every new platform needs all of them; test
  fakes are about 500 lines.
- **Solution:** split into role interfaces (`VpnControl`, `RuleAdmin`,
  `LogReader`, `AiEngine`, `HealthSource`), with the native class
  implementing all of them.
- **Priority:** P2. **Risk:** low (mechanical).

### A4: Cross-language duplication
- **Problem:** category ids, default AI thresholds (`ai_models.dart` and
  `ThresholdProfiles.kt`) and domain validation (`domain_input.dart` and
  `DomainName.kt`) exist twice.
- **Impact:** they can drift. Native is authoritative for enforcement, so
  drift shows up as a UI mismatch rather than a bypass.
- **Solution:** add a parity test that reads both definitions (the JVM test
  can parse the Dart constants file), or have native send its defaults
  over the channel at start-up.
- **Priority:** P2. **Risk:** low.

### A5: Native code needs Android to test
- **Problem:** VPN, channel and SQLite code can only be tested with
  Robolectric or on a device.
- **Solution:** keep putting decisions into `engine/**` pure classes and
  keep the Android layer as thin adapters. Phase 8 followed this for
  updates, the health-monitor policy, decision explanations and traces.
- **Priority:** P2.

### A6: Tests that never ran
- **Problem:** `android/app/src/test/.../data/**` (Robolectric + real
  SQLite) never ran in the development container.
- **Solution:** a CI job on GitHub-hosted runners, which have the Android
  SDK: `.github/workflows/ci.yml`.
- **Priority:** P1.

### A7 / A8: Updates
- **Problem:** lists and model are frozen at build time; APK size.
- **Solution:** `engine/updates/**` (implemented in Phase 8): signed
  manifest (ECDSA P-256, supported on every Android version the app
  runs on; Ed25519 needs API 33), version / expiry / compatibility
  checks, SHA-256 payload binding, staged write + atomic activation,
  rollback, bounded storage. **Transport isn't implemented** because
  there is no server. Design: `UPDATE_ARCHITECTURE.md`.
- **Priority:** P2. **Risk:** low: not wired into the live rule path
  until a server exists.

### A9: Health only on demand
- **Solution (implemented):** `HealthMonitorPolicy` (pure, tested) drives
  a check every 15 minutes while the VPN runs, plus on network change. It
  recovers what it safely can (AI model reload, database re-check) with
  exponential backoff and a cap, and posts a notification when protection
  is degraded (if the user allowed notifications).
- **Priority:** P1.

### A10: i18n approach
- `tr(ar, en)` keeps both strings side by side and makes a missing
  translation impossible; a widget test fails on any Arabic text in
  English mode. It doesn't scale to many languages or to translators.
  Move to ARB + `gen-l10n` only when a third language is planned.

### A11: Queries on the channel thread
- The channel uses one IO thread, so a slow statistics query delays other
  calls. The desktop measurement was ~15 ms for all windows. Revisit
  after phone measurements (`PERFORMANCE.md`).

### A12: Debug fixtures in main
- `BuiltInRules.testFixtures` ships in release but is only used when the
  build is debuggable, and is removed if found in release. Moving it to
  `src/debug/` would remove the code from release entirely.

### A13: Block-reason explanations
- **Implemented:** `engine/explain/DecisionExplanation` maps every
  decision (DNS rule reasons, keyword, AI threshold, protected app,
  unknown) to a stable code. The UI translates the codes. A content-free
  `DecisionTrace` ring buffer records stage outcomes without subjects.

### A14: Parser fuzzing
- `DnsMessage`/`Ipv4Udp` parse untrusted bytes. The code is
  bounds-checked, but no fuzzing has been done. Recommended: Jazzer (JVM)
  in CI.

### A15: Dependencies
- Runtime: `crypto` (PBKDF2's HMAC), `flutter_secure_storage` (Keystore),
  `go_router`, `shared_preferences`. Dev: `flutter_lints`, `flutter_test`.
  Kotlin: none beyond the Flutter embedding. No analytics, ads or crash
  SDKs. Dependabot is configured to watch pub, Gradle and Actions.
