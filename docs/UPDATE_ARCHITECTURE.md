# Update architecture (design only, not implemented)

SafeGuard 1.6.0 downloads nothing. Domain lists, search rules and the AI
model ship inside the APK and are updated only by app updates through
Google Play. This document fixes the rules that any future remote update
must follow, so it can't be added insecurely later.

## Principles

1. **Data, never code.** Updates carry rule data and model weights in
   fixed, parsed formats (`SGBL` lists, the `sg_text` model format, JSON
   config with a schema). No DEX, native libraries, scripts, WebView
   content or dynamic class loading. Play policy forbids downloading
   executable code anyway.
2. **The APK's copy is the floor.** A bad or missing update never leaves
   the device with less than what shipped in the APK.
3. **Verify before replacing.** Nothing becomes active until its
   signature, hash, version and schema are all checked.
4. **Fail safe, fail quietly.** Update errors never stop filtering. They
   show up as a status line and in Diagnostics, never as a crash.

## Package format

```
update.json  (signed manifest)
{
  "schema": 1,
  "kind": "domain-list" | "search-rules" | "category-rules" | "ai-model" | "config",
  "id": "gambling",
  "version": 42,                 // strictly increasing per id
  "minAppVersion": "1.7.0",      // compatibility gate
  "createdAt": "2026-10-01T00:00:00Z",
  "expiresAt": "2027-01-01T00:00:00Z",
  "payload": { "url": "https://…/gambling-42.sgbl", "size": 2741003,
               "sha256": "…" },
  "modelMeta": { "format": "sg_text", "formatVersion": 1,
                 "dims": 8192, "categories": [...] }   // ai-model only
}
update.json.sig  (Ed25519 over the exact manifest bytes)
```

- **Signing:** Ed25519 keys held offline by the publisher. The APK pins
  **two** public keys (current + next) so the key can rotate without an
  app update. No private key ever reaches CI or the app.
- **Transport:** HTTPS only, with a Network Security Config that denies
  cleartext and pins the update host's SPKI (plus a backup pin). TLS
  protects the transport, and the signature protects the content even if
  TLS or the host is compromised.
- **Authentication:** requests are anonymous GETs with no device ID, no
  account and no cookies. If the server needs to limit abuse, it uses a
  short-lived token issued per request, never a secret embedded in the
  APK.

## Client pipeline

```
schedule (WorkManager, unmetered + charging preferred, ≤ 1/day)
  → GET manifest + signature (HTTPS, pinned)
  → verify Ed25519 signature (pinned keys)          ✗ → reject, keep current
  → check kind/id known, schema == supported         ✗ → reject
  → version > installed version (no downgrade)      ✗ → ignore
  → minAppVersion ≤ app version                     ✗ → ignore (log)
  → now < expiresAt                                  ✗ → reject
  → size ≤ per-kind cap (lists 16 MB, model 8 MB)    ✗ → reject
  → download payload to files/updates/tmp/<id>-<version>
  → SHA-256(payload) == manifest.sha256              ✗ → delete, reject
  → parse fully (HashedDomainList.parse / TextModel.parse / schema)
                                                     ✗ → delete, reject
  → sanity checks (entry-count bounds; NeverBlock domains absent;
    model evaluates a fixed probe set within tolerance)
                                                     ✗ → delete, reject
  → atomic activate: rename tmp → files/updates/<id>/<version>,
    then write the "active" pointer (single atomic file write)
  → engine.invalidate() / reload model
  → keep the previous version for rollback; delete older ones
```

## Rules per requirement

| Requirement | How |
|---|---|
| Signed packages | Ed25519 manifest signature; payload bound by SHA-256 in the signed manifest |
| Versioning | Monotonic `version` per `id`; downgrades refused (prevents rollback attacks) |
| Rollback | Previous version kept; a user action or a failed post-activation health check switches the pointer back. The APK's copy is the final fallback |
| Expiration | `expiresAt` checked before activation, and again at load: an expired update is dropped in favour of the previous version or the APK copy |
| Schema validation | Strict parsers that reject unknown formats and versions (`SGBL` v1 and the model header already do this) |
| Duplicate prevention | `(id, version)` is unique; the same version is never downloaded twice; lists are sorted and deduplicated at build time and the parser rejects unsorted input |
| Atomic updates | Write to tmp, fsync, rename, then flip the pointer; never modify the active file in place |
| Corrupted update rejection | Size cap, SHA-256, full parse and sanity checks, all before activation |
| Offline fallback | No network → nothing changes; the last valid local version stays active indefinitely (a "lists last updated" date is shown) |
| Storage limits | Per-kind caps; at most 2 versions per id; cleanup after activation |
| Old model cleanup | After a successful activation, delete all versions except active and previous |
| Never replace an active model before validation | Activation is the last step; inference keeps using the loaded model until the swap |

## Code already in place

- `HashedDomainList.parse` validates the magic, version, sort order and
  size. `BundledLists` pins the SHA-256 of each shipped list.
- `ModelLoader` verifies size and SHA-256 before parsing. `TextModel.parse`
  validates the header.
- `CompositeRuleStore` and `BundledListStore` can take a provider function,
  so an updated list set can be swapped atomically by replacing the
  provider's reference (a `@Volatile` list in `ProtectionManager`).

## Not planned

- Remote configuration of feature flags or thresholds that could weaken
  protection without the user's PIN.
- Telemetry "phone home" as part of update checks.
