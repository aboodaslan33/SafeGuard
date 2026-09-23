# Performance

**All numbers below were measured on the JVM in the development
container: JVM 21, 4 CPUs, a server machine, not a phone.** They show
the relative cost of the engine's logic. They are **not** phone
measurements. No figure for phone startup time, memory, CPU, battery or
end-to-end DNS latency has been measured yet; those rows say
**NOT MEASURED** and give the method.

## Measured (JVM, 2026-09-23, after the Phase 7 changes)

Source: `Phase5BenchmarkTest`, `BundledListsTest` and `AiBenchmarkTest`
(outputs in the harness `build/*.txt`), re-run in this phase.

| What | Result |
|---|---|
| Rule set in memory (102,000 rules, benchmark store) | index built in 59 ms, ~31 MiB heap |
| Rule decision, cache miss (deep subdomain) | 5.69 µs |
| Rule decision, cache hit | 0.40 µs |
| Bundled lists (1,322,045 entries): cold lookup, 4 suffixes × 3 lists | 7.19 µs |
| DNS packet → decision (+ NXDOMAIN reply), in-process | 0.57 µs/query |
| Custom keyword match, 500 keywords | 7.43 µs/query |
| Health evaluation (logic only) | 0.14 µs |
| Text model load + SHA-256 verify + parse (once) | 1.07 ms median |
| Text model heap after load | ~194 KiB |
| Text inference per query | 35.4 µs median |
| Image preprocess 1000×750 → 224×224×3 | 7.6 ms median (no image model ships) |
| Statistics, 9 queries over 10,000 events (desktop SQLite, Phase 5) | ~15.5 ms |

Size facts (exact):
- Bundled lists: 10.6 MB (gambling 2,741,003 B + sexual 7,627,161 B +
  drugs 208,248 B), stored uncompressed and memory-mapped, not copied
  to the Java heap.
- Text model: 197,713 B.

## Not measured on a phone yet

| Metric | Status | How to measure (release build, prod flavour) |
|---|---|---|
| Cold start time | NOT MEASURED | `adb shell am start -W -n com.safeguard.app/.MainActivity` ×10, report the median `TotalTime` |
| Memory | NOT MEASURED | `adb shell dumpsys meminfo com.safeguard.app` (PSS total) with protection on, idle and after browsing 20 sites |
| CPU | NOT MEASURED | `adb shell top -n 30 -d 1 \| grep safeguard` while browsing; idle should be ~0% because the VPN loop blocks in `poll()` |
| VPN overhead / DNS latency | NOT MEASURED | `adb shell ping -c 20 <host>` doesn't use DNS; instead time page loads with and without protection on the same site list, or run `dig` from Termux against the system resolver |
| DNS behaviour | NOT MEASURED | blocked → NXDOMAIN immediately; allowed → forwarded; offline → SERVFAIL immediately (implemented and unit-tested; not timed on a phone) |
| AI inference on a phone | NOT MEASURED | time a SafeGuard search with the AI on (debug log timing isn't in release) |
| Battery | NOT MEASURED | `adb shell dumpsys batterystats --reset`, 24 h normal use with protection on, then `dumpsys batterystats com.safeguard.app` (or Settings → Battery usage) |
| APK / AAB size | NOT MEASURED | `flutter build appbundle --release --analyze-size` |

Record phone results in this file with the device, Android version,
build and date, next to the JVM numbers, never in place of them.
