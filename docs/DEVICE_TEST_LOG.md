# Real-device test log

Results reported by the project owner. Recorded as reported; nothing
here was observed by the developer directly.

## 2026-09-23 — Infinix X6528, Android 13 (API 33), debug build via `flutter run`

Build: branch `claude/vigilant-newton-8ngu21` @ `ea835db` (Phase 5), Flutter
3.47.5 / Dart 3.13.4 on Windows 11. **First successful build and install on a
real device.**

| # | Test | Result |
|---|---|---|
| D1 | App builds, installs and runs | PASS |
| D2 | Protection on → browser search for an explicit term: no sexual results (SafeSearch enforced via DNS). Protection off → explicit results appear. (P3-1) | PASS |
| D3 | Adult domain added to the custom blocklist → opening it shows "access blocked" | PASS |
| D4 | Protection on → search for gambling / gambling stories: gambling platforms were listed | Expected at that build: no gambling domain lists were bundled and SafeSearch does not hide gambling. **Fixed after this test** by bundling category lists (docs/LISTS.md); not yet re-tested |
| D5 | Instagram: wants sexual content hidden | Out of scope for DNS filtering (content comes from Instagram's own servers). Options documented: Instagram's *Sensitive content → Less*, or App Protection / blocking Instagram entirely |

Next on-device checks: re-test D4 with the bundled lists (open a known
gambling site), P4 and P5 manual cases, reboot behaviour on Infinix (XOS
battery management), `cd android && .\gradlew test` on the owner's machine
(runs the Robolectric SQLite tests that could not run in the development
environment).
