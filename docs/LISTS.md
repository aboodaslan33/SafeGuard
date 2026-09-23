# Bundled domain lists

| Category | Asset | Entries | Size | SHA-256 |
|---|---|---|---|---|
| Gambling | `android/app/src/main/assets/lists/gambling.sgbl` | 342,623 | 2,741,003 B | `edbcb7ae…f00f9d` |
| Sexual | `…/lists/sexual.sgbl` | 953,393 | 7,627,161 B | `44f28f92…d116d9` |
| Drugs | `…/lists/drugs.sgbl` | 26,029 | 208,248 B | `f8f9d4f0…ed8db367` |

Exact values are pinned in `engine/rules/BundledLists.kt` and checked by
`DomainListBuildTest.shippedListsMatchTheirPins` (build) and at runtime
before a list is used.

## Source and licence

- **The Block List Project** — https://github.com/blocklistproject/Lists
  (`gambling.txt`, `porn.txt`, `drugs.txt`, hosts format), downloaded
  2026-09-23; file headers dated 2026-07.
- Repository licence: **Unlicense** (public domain dedication). The list
  files' headers state **MIT**. Both allow redistribution in an app.
- The project aggregates upstream sources automatically. Their individual
  licences were not reviewed one by one; before a commercial release, the
  owner should confirm the provenance they are comfortable with.
- Source file SHA-256 (as downloaded): gambling
  `d583202e…9cf439`, porn `425590c3…0b4db1`, drugs `f88d4e83…af4e2fc`.

## Format and matching

Sorted 64-bit FNV-1a hashes of exact hostnames (`HashedDomainList`). A
name is checked together with its parent suffixes, so an entry covers
itself and its subdomains, never its parent or siblings
(`some-blog.tumblr.com` blocks that blog, not Tumblr). Lists are
memory-mapped (stored uncompressed in the APK: `noCompress += "sgbl"`).

Precedence is the normal rule engine's: user allowlist → user blocklist →
list rule (only if its category is enabled) → unknown allowed.

`NeverBlock` (core platforms and shared-hosting roots: Google, Instagram,
WhatsApp, Tumblr, Blogspot, CDNs…) can't be blocked by an exact list entry,
at build time and again at lookup time.

## Quality — what to expect

- These are large, automatically maintained lists: they miss new sites and
  may contain mistakes (a legitimate site listed). Users fix a false
  positive by adding the domain to **النطاقات المسموحة**.
- No lists exist in this build for violence, gore or dangerous content.
- Search result pages (Google etc.) can still *show* gambling results; the
  listed sites themselves don't open.

## Updating

```
# 1. Download the three hosts files into a directory, e.g. /tmp/lists
# 2. Rebuild the assets (JVM test harness or ./gradlew test):
SG_LIST_SRC=/tmp/lists SG_SAMPLES_OUT=android/app/src/test/resources/lists/samples.txt \
  ./gradlew test --tests '*DomainListBuildTest.buildFromSources*'
# 3. Copy entries/size/sha256 from build/lists-report.txt into BundledLists.kt
# 4. Run all tests.
```
