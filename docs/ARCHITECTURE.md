# SafeGuard — Architecture (Phase 2)

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
Categories: `SEXUAL, VIOLENCE, GORE, GAMBLING, DRUGS, DANGEROUS, SAFE, UNKNOWN`.
Sources: `BUILT_IN, USER, REMOTE (future), TEST (debug builds only)`.

Precedence (first match wins):

1. Protection off → ALLOW.
2. User **allowlist** entry on the domain or any parent → ALLOW.
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
| `DomainClassifier` | `engine/rules/RuleEngine.kt` | AI/heuristic classification of unknown domains. |
| `UnknownDomainPolicy.BLOCK` | same | Strict Mode. |
| `SearchFilterService` | `engine/search/` | Search-query classification / SafeSearch. |
| `ImageClassifier`, `AppProtectionPolicy`, `SettingsSync` | `engine/extensions/` | Image, per-app and family-dashboard features. |
