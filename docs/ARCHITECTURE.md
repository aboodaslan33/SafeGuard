# SafeGuard — Architecture (Phases 2–5)

## Layers

```
Flutter UI (Home / Status / Rules / Activity)
    │  ProtectionController (intent + live status)
    │  ProtectionEngine  ← port (Dart interface)
    │  NativeProtectionEngine → ProtectionChannel (typed Dart wrapper)
    ▼
Platform channels
    MethodChannel  com.safeguard.app/protection
    EventChannel   com.safeguard.app/protection/status
    ▼
Kotlin  channel/ProtectionChannel      (args validation, threading, error codes)
    ▼
Kotlin  protection/ProtectionManager   (facade: config, rules, logs, stats, status)
    │         protection/ProtectionConfigStore  (native copy of the policy)
    ▼
Kotlin  vpn/SafeGuardVpnService        (tun lifecycle, poll loop, revoke, always-on)
    │         vpn/NetworkMonitor       (Wi-Fi ↔ mobile, DNS servers, Private DNS)
    │         vpn/DnsForwarder         (allowed queries → network's own resolver)
    ▼
Kotlin  engine/dns/DnsPacketFilter     (IPv4/UDP + DNS parse → decision → reply)
    ▼
Kotlin  engine/rules/RuleEngine        (precedence, suffix matching, LRU cache)
    │         engine/rules/RuleStore   ← data/SqliteRuleStore (SQLite, indexed)
    ▼
ALLOW → forward upstream        BLOCK → NXDOMAIN + BlockLogger → SQLite
```

Everything under `engine/` is **pure Kotlin** (no `android.*` imports), so
the DNS codec, rule engine, logging, statistics and status model are unit
tested on the JVM (`android/app/src/test/kotlin/.../engine`).

## How the VPN sees only DNS

`SafeGuardVpnService` builds a tun interface with:

| Builder call | Value | Why |
|---|---|---|
| `addAddress` | `10.111.222.1/32` | Private address for the tun. |
| `addDnsServer` | `10.111.222.2` | Android hands this resolver to every app. |
| `addRoute` | `10.111.222.2/32` | **Only** DNS to that virtual server enters the VPN. All other traffic uses the normal network, unseen. |
| `addDisallowedApplication` | own package | SafeGuard's upstream sockets never loop into its own VPN. |
| `setUnderlyingNetworks` | current physical network | Correct metering / connectivity reporting; updated on every network change. |
| `setMetered(false)` (API 29+) | | Metered-ness follows the real network. |

The worker thread blocks in `Os.poll()` on the tun fd plus an interrupt
pipe, so it uses no CPU while idle and stops instantly on shutdown.

Per packet:

1. `Ipv4Udp.parse` — rejects non-IPv4, non-UDP, fragments, truncated or
   inconsistent lengths.
2. `DnsMessage.parseQuery` — standard queries with one question only;
   bounds-checked; compression pointers followed with a hop limit and must
   point backwards (no loops).
3. `RuleEngine.evaluate` → `Decision`.
4. **BLOCK:** reply immediately with `NXDOMAIN` (same ID and question, no
   answers). Nothing is connected, every OS resolver and browser handles
   it. The block is logged asynchronously.
5. **ALLOW:** `DnsForwarder` sends the query to the physical network's own
   DNS servers through a `protect()`ed socket bound to that network, checks
   the answer ID, and writes the answer back. No upstream (offline/airplane
   mode) → immediate `SERVFAIL`, so apps fail fast; blocking still works.

## Rule engine

Rule = `domain, category, action, enabled, source, version, updatedAt`.
Categories: `SEXUAL, VIOLENCE, GORE, GAMBLING, DRUGS, DANGEROUS, SAFE, UNKNOWN`,
and (Phase 5) `CUSTOM` for the user's own blocks/keywords (not a toggle).
Sources: `BUILT_IN, USER, REMOTE (future), TEST (debug builds only)`.

Precedence (first match wins):

1. Protection off → ALLOW.
2. User **allowlist** entry → ALLOW. Since Phase 5 an entry covers its
   subdomains only if added with `includeSubdomains`; otherwise just the
   domain and `www.` (entries from earlier versions keep covering subdomains).
3. User **blocklist** entry on the domain or any parent → BLOCK (explicit
   intent; applies whatever the category toggles).
4. Most specific list rule (longest domain; BLOCK wins a tie):
   SAFE/ALLOW → ALLOW; otherwise BLOCK only if its category is enabled.
5. `DomainClassifier` hook (Phase 2: none).
6. UNKNOWN → `UnknownDomainPolicy.ALLOW`. `BLOCK` exists only as the
   Strict Mode hook; nothing in the UI can select it.

**Matching** is label-based: `a.b.example.com` is looked up as
`[a.b.example.com, b.example.com, example.com]` in **one** indexed SQL query
(`domain IN (…)`, verified to use `idx_rules_domain`). `safe-example.com`
never matches `example.com`. Results are cached per domain in a 4096-entry
LRU that stores matching *rules*, not decisions, so category toggles apply
instantly; any rule change invalidates it.

## Data

SQLite `safeguard.db` (app-private, excluded from backup):

- `rules` — `UNIQUE(domain, source)`, indexes on `domain` and `(source, action)`.
- `block_events(ts, domain, category)` — index on `ts`; pruned to 30 days /
  10 000 rows.
- `counters` — lifetime blocked total (survives pruning).
- `meta` — built-in list version / debug fixture flag.

All queries use bound parameters; `LIKE` wildcards in searches are escaped.
SQL syntax is limited to what Android 7's SQLite supports (no UPSERT).

The Flutter policy (`ProtectionState`) stays in Flutter's storage and is
mirrored to `ProtectionConfigStore` (SharedPreferences) on every change and
on every app start, because the VPN must work when Flutter isn't running.

## Logging

`BlockLogger` records `(timestamp, domain, category)` on a single background
thread. Repeats of the same domain within 30 s are counted once (one page
load issues A, AAAA and HTTPS lookups, plus retries). Nothing else is ever
stored: no app identity, IPs, URLs, content, cookies or credentials.

## Lifecycle

| Event | Behaviour |
|---|---|
| Start from UI | Explanation sheet → `VpnService.prepare` system dialog → start. |
| App closed / swiped away | VPN keeps running (the system binds established VPN services). |
| Process killed | `START_STICKY` restart re-establishes the VPN if protection is on and consent exists. |
| Network switch / airplane mode | tun stays up; upstream network and underlying networks are updated. |
| Another VPN starts / user disconnects in Settings | `onRevoke` → status `REVOKED`; SafeGuard never fights back or auto-restarts over another VPN. |
| Reboot | `BootReceiver` (best effort) or Android **Always-on VPN** (reliable; service supports `SUPPORTS_ALWAYS_ON`). |
| Consent withdrawn | status `PERMISSION_REQUIRED`; UI asks again only on user action. |

## Extension points (interfaces only, not implemented)

| Interface | File | Future use |
|---|---|---|
| `RemoteRuleSource` | `engine/rules/RuleSources.kt` | Signed, versioned category-list downloads. |
| `HostsListParser` | same | Import hosts-format lists (implemented, unused). |
| `DomainClassifier` | `engine/rules/RuleEngine.kt` | Heuristic classification of unknown domains. Deliberately **not** wired to AI (every DNS lookup; false positives break sites). |
| `UnknownDomainPolicy.BLOCK` | same | Strict Mode. |
| `ImageModelRuntime` | `engine/ai/image/` | An on-device image model (none shipped). |
| `CloudTransport` | `engine/ai/ClassifierGuards.kt` | Optional, consented, encrypted cloud classification (none shipped). |
| `VideoSampler` | `engine/ai/video/` | Interval-sampled video frames (not wired). |
| `SettingsSync` | `engine/extensions/` | Family dashboard. |

## Phase 3 additions

```
SafeGuard search box (Flutter, on submit)
    → submitSearch (channel) → ProtectionManager.submitSearch
    → RuleBasedSearchFilterService
        SearchNormalizer → SearchClassifier (RuleBased | Combined w/ Phase 4 AI)
        → SearchPolicy (categories shared with DNS, threshold 0.6)
        → SearchEventRecorder (BLOCK only: rule id + keyed hash)
    → ALLOW: open results URL with the engine's safe parameter
      BLOCK: Flutter shows the block screen

DNS path (VPN): RuleEngine → [BLOCK: NXDOMAIN]
                           → SafeSearchRewriter.targetFor(name)?
                               A/AAAA/CNAME/ANY: ask upstream for the target,
                                 DnsRecords.synthesizeCname(name → target + records)
                               other types (HTTPS/SVCB…): NODATA
                           → otherwise forward unchanged

AppGuardService (Accessibility, window-state events only, no window content)
    → ProtectionManager.onForegroundApp(pkg) → AppProtection.decide
    → BLOCK_APP: event (source APP) + GLOBAL_ACTION_HOME + AppBlockedActivity
```

| Component | File | Notes |
|---|---|---|
| `SearchNormalizer` | `engine/search/SearchNormalizer.kt` | NFKC/NFD, Arabic unification, digits, variants |
| `SearchClassifier`, `RuleBasedSearchClassifier`, `CombinedSearchClassifier` | `engine/search/SearchClassifier.kt` | **Phase 4 plug-in point** |
| `BuiltInSearchLexicon` | `engine/search/SearchLexicon.kt` | Small, generic, id-addressed rules + safe contexts |
| `SearchPolicy`, `RuleBasedSearchFilterService` | `engine/search/SearchFilterService.kt` | Thresholds per category |
| `QueryHasher`, `SearchEventRecorder` | `engine/privacy/` | HMAC-SHA256, per-install key, 32-bit |
| `SafeSearchRewriter`, `SafeSearchConfig` | `engine/safesearch/` | Official endpoints only |
| `DnsRecords` | `engine/dns/DnsRecords.kt` | Decompressing RR parser, uncompressed writer |
| `AppProtection`, `AccessibilityStateResolver` | `engine/apps/` | Validation, exemptions, decisions |
| `AppGuardService`, `AppBlockedActivity` | `apps/` | Android-only |
| `SqliteProtectedAppStore` | `data/` | In-memory cache (service runs on main thread) |
| DB v2 | `data/SafeGuardDatabase.kt` | Event columns: source, action, confidence, rule_type; `protected_apps` |

Events: `BlockEvent(timestamp, subject, category, source, action,
confidence, ruleType)` (`ProtectionEvent` alias). Subjects are never user
text for SEARCH.

## Phase 4 additions (AI)

Full design, measurements and limits: [`PHASE_4_AI.md`](PHASE_4_AI.md).

```
AiSearchFilterService (replaces RuleBasedSearchFilterService in ProtectionManager)
  rules (Phase 3 lexicon + SearchPolicy) ── BLOCK ─→ done
  └→ GuardedContentClassifier (score cache, rate limit)
       └→ AdapterContentClassifier → LocalTextClassifierAdapter (sg-text-1, asset, SHA-256 pinned)
  └→ ProtectionDecisionEngine (rule signal + AI result + AiSettings + categories)
       → BLOCK (event source AI) | UNKNOWN (allowed) | ALLOW

checkImage (channel, system picker) → ProtectionManager.checkImage
  → LocalImageClassifierAdapter: ImageHeaderParser → sample plan → BitmapImageDecoder
    → ImagePreprocessor → ImageModelRuntime (none shipped → NO_MODEL)
  → ProtectionDecisionEngine → AiStatsRecorder / BlockLogger
```

| Component | File |
|---|---|
| `ContentClassifier`, `ClassifierAdapter`, `AdapterContentClassifier` | `engine/ai/ContentClassifier.kt` |
| `ProtectionDecisionEngine`, `AiSettings`, `ThresholdProfiles`, `ConflictPolicy` | `engine/ai/ProtectionDecisionEngine.kt` |
| `GuardedContentClassifier`, `InferenceBudget`, `CloudClassifierAdapter` | `engine/ai/ClassifierGuards.kt` |
| `TextFeatures`, `TextModel`, `LocalTextClassifierAdapter` | `engine/ai/text/` |
| `ImageHeaderParser`, `ImagePreprocessor`, `LocalImageClassifierAdapter` | `engine/ai/image/ImagePipeline.kt` |
| `BuiltInModels`, `ModelLoader` | `engine/ai/model/ModelRegistry.kt` |
| `VideoSampler` (not wired) | `engine/ai/video/` |
| `AiStatsStore`, `FalsePositiveReport` | `engine/ai/AiStats.kt`; SQLite: `data/SqliteAiStatsStore.kt` |
| `BitmapImageDecoder` (Android) | `ai/BitmapImageDecoder.kt` |
| DB v3 | `ai_feedback` table; AI counters in `counters` (`ai_*`) |
| Trainer + seed set (build-time, test sources) | `src/test/.../ai/TextModelTrainer.kt`, `src/test/resources/ai/text_seed_v1.tsv` |

## Phase 5 additions (advanced protection)

Details: [`PHASE_5_REPORT.md`](PHASE_5_REPORT.md), plan: [`PHASE_5_PLAN.md`](PHASE_5_PLAN.md).

```
Flutter ProtectionState {enabled, categories (user), mode}
  → setConfiguration {enabled, categories, mode}
  → ProtectionConfigStore
       raw user settings ── ProtectionModes.resolve(mode) ──► effective
       + TemporaryUnlock (wall + elapsed clocks) + safeMode
       → policy / safeSearch / searchPolicy / effectiveAi  (read per query)

Search: CustomKeywords → lexicon (mode threshold) → AI → ProtectionDecisionEngine
DNS:    RuleEngine (user allowlist scope: exact | subdomains) → …

Health: ProtectionManager.health() → ProtectionHealthEvaluator
        ← status, consent, upstream failures, rules, AI model, apps/a11y, DB
Recovery: filter-loop crash (service) / app resume (tryRecover) → RecoveryPolicy
Interruptions: status listener + a11y check → IncidentDetector → IncidentLog (prefs)
Boot: BootReceiver → settings → Safe Mode → consent → start; outcome recorded
```

| Component | File |
|---|---|
| `ProtectionMode`, `ProtectionModes` | `engine/modes/ProtectionModes.kt` |
| `ProtectionHealthEvaluator`, `HealthInputs`, `HealthReport` | `engine/health/ProtectionHealth.kt` |
| `RecoveryPolicy`, `IncidentDetector`, `IncidentLog`, `UpstreamHealth` | `engine/health/Recovery.kt` |
| `TemporaryUnlock` | `engine/pause/TemporaryUnlock.kt` |
| `UserRules` (validation, duplicates, conflicts) | `engine/rules/UserRules.kt` |
| `CustomKeywords` | `engine/search/CustomKeywords.kt`; SQLite: `data/SqliteCustomKeywordStore.kt` |
| `StatisticsService.detailed()` | `engine/stats/Statistics.kt` |
| DB v4 | `rules.include_subdomains`, `custom_keywords` |
| Flutter `ProtectionGuard` (PIN policy), `AdvancedActions`, `SettingsExport` | `lib/features/protection/presentation/`, `lib/features/advanced/` |

## Phase 6–8 additions

### Security and privacy (Phase 6)
- The event/cache HMAC key is a non-exportable Keystore key
  (`KeystoreHmacKey` → `MacProvider`).
- The PIN lockout is anchored to `elapsedRealtime` + boot count.
- Log retention (`LogRetention`). R8 and signing from `key.properties`.

### Product surface (Phase 7)
- `core/i18n`: `tr(ar, en)` at call sites. The language setting rebuilds
  the tree; native screens read `ui_language`.
- Onboarding (8 pages) → PIN → **setup wizard** (router gate
  `setupPending`).
- **Setup assistant:** pure `evaluateSetup(SetupFacts)` plus a UI.
- **Diagnostics:** `DiagnosticReport` whitelist and sanitiser.
- Flavours: `dev` / `staging` / `prod` (`default-flavor: prod`), exposed
  as `AppInfo`.

### Maintainability and operations (Phase 8)

```
engine/updates    UpdateManifest (strict schema) · UpdateSignatureVerifier (ECDSA P-256)
                  UpdateStore (stage → verify → atomic activate → rollback → cleanup)
                  UpdateValidators (sgbl list / text model + probe)      [no transport]
engine/explain    Explanation codes · DecisionExplainer · DecisionTrace (content-free ring buffer)
engine/health     HealthMonitorPolicy (repairs + notifications) · Backoff
engine/backup     UserConfigBackup (lists, keywords, apps → private file)
protection/       ProtectionAlerts (single "degraded" notification)
                  ProtectionManager.monitorTick() ← SafeGuardVpnService (15 min, network change)
lib/core/observability   CrashReporter (LocalCrashReporter) · Telemetry (LocalTelemetry, opt-in)
lib/core/entitlements    Plan / ProtectionFeature (never gated) / EntitlementSource
lib/features/feedback    FeedbackDraft (exact preview) · FeedbackScreen · AnalyticsScreen
```

**Health loop:**

```
VPN running ─every 15 min / network change─▶ monitorTick()
  health() ─▶ HealthMonitorPolicy.repairs()
                ├─ AI model broken  → textAdapter.resetFailure()  (backoff)
                ├─ DB failing       → re-check, clear failure flag (backoff)
                └─ lists missing    → reload bundled lists         (backoff)
  re-check health() ─▶ notifications() ─▶ ProtectionAlerts.show / clear
VPN revoked / recovery exhausted ─▶ alertStopped() (immediate)
```

**Errors and observability:**
`AppLogger.error(tag, …)` → `AppDependencies.observeErrors()` → telemetry
count (only if opted in) + crash record (for crash tags). The error
message is never stored.

**Explanations end to end:**
native decision → `DecisionExplainer` code → event map `explanation` /
search result `explanation` → Dart `DecisionExplanation` → localized
reason (log row, block screen, trace). A parity test checks that the Dart
and Kotlin ids match.

See also: `ARCHITECTURE_REVIEW.md` (debt and next refactors),
`UPDATE_ARCHITECTURE.md`, `DATABASE_MIGRATIONS.md`, `PRIVACY.md`,
`THREAT_MODEL.md`, `../SECURITY.md`.

## Final AI phase: AI Content Shield (1.8.0)

Details, model evaluation and measurements: `docs/AI_CONTENT_SHIELD.md`.

```
engine/shield (pure Kotlin)
  AiLabel · AiClassification {label, confidence, modelVersion}
  ShieldScores → ClassificationResult ─▶ ProtectionDecisionEngine (unchanged authority)
  TemporalConfirmer · FrameGate · FrameHash · InferenceWatchdog
  VisibleTextExtractor (NodeView) · SupportedApps · ShieldSettings · ShieldStatusResolver
  ImageModelPack (sg-image-pack/1) · ShieldImageClassifier · BuiltInImagePacks (empty)
  ContentShieldEngine (orchestration)
shield/ContentShieldService   2nd accessibility service, packageNames = supported apps
apps/AppBlockedActivity       + content variant (category only)
ProtectionManager             shield wiring, status, settings, metadata-only log
lib/features/shield           ContentShieldScreen (/ai-shield)
```

The shield adds evidence; it never bypasses the policy engine. It is off
by default; text AI is real (sg-text-1), and image AI is unavailable
because no model is bundled.
