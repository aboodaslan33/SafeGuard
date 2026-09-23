# Release checklist

`[x]` means done **and** backed by the evidence named. `[ ]` means not
done or not verified. State as of version 1.7.0+8, end of Phase 8.
**The app is not ready for production release**: the unticked boxes,
especially the real-device ones, are open.

## Required items

- [x] **Security audit complete:** Phase 6 audit (docs/PHASE_6_SECURITY.md) plus the Phase 7 production code review (docs/PHASE_7_REPORT.md §1). Automated guards in `Phase6Test`.
- [x] **Privacy audit complete:** docs/PHASE_6_SECURITY.md §3–§14; diagnostics privacy test (`phase7_test`).
- [x] **Threat model complete:** docs/THREAT_MODEL.md (updated for Phase 8: T10–T15).
- [x] **Permissions reviewed:** docs/GOOGLE_PLAY.md §3 (4 permissions incl. the optional runtime POST_NOTIFICATIONS added in Phase 8, + 2 service bindings).
- [ ] **VPN tested:** consent + start on one device with a debug Phase 5 build only (DEVICE_TEST_LOG D1–D3). Revoke, other-VPN, network switching and reboot are NOT EXECUTED (TEST_MATRIX M6, M17–M20, M23–M24).
- [ ] **DNS tested:** a custom-blocklist domain was blocked on a device (M7 PASS). Bundled lists (M8), offline (M18) and upstream failure (M19) are NOT EXECUTED.
- [ ] **Search filtering tested:** SafeSearch PASS on device (M9); SafeGuard search with Arabic/English/mixed queries NOT EXECUTED (M10).
- [ ] **App protection tested:** logic unit-tested only; NOT EXECUTED on a device (M11–M12).
- [ ] **AI tested:** unit-tested and benchmarked on the JVM; NOT EXECUTED on a device (M13–M14).
- [ ] **PIN tested:** unit and widget tested (lockout, clock change, restart with a fake monotonic clock); NOT EXECUTED on a device (M4–M5).
- [ ] **Database tested:** JVM failure-path and backup tests pass; the Robolectric SQLite + v1→v4 migration tests pass on CI. Not tested on a device (a real upgrade from an installed older version).
- [ ] **Release build tested:** an unsigned `flutter build apk --release --flavor prod` (R8) **builds on CI**. A signed AAB has not been built (no upload key yet), and no release build has been run on a device.
- [x] **No debug secrets:** none in the source (Phase 6 audit); signing keys are read from a gitignored `key.properties`.
- [x] **No test endpoints:** the app has no network endpoints at all; `Phase6Test.noCleartextEndpointsOrWebViews`.
- [x] **Privacy documentation ready:** privacy text in docs/STORE_LISTING.md, in-app Privacy screen. **Still needed:** host it at a public URL for Play.
- [x] **Store materials ready (drafts):** docs/STORE_LISTING.md (Arabic + English). **Still needed:** screenshots, feature graphic, support contact, publisher review.
- [ ] **Crash handling verified:** fail-safe paths are implemented and unit-tested (DB errors, log write errors, VPN recovery races). Not verified on a device (M31–M33).
- [ ] **Performance tested:** JVM microbenchmarks only (docs/PERFORMANCE.md). Phone startup, memory, CPU and battery are NOT MEASURED.
- [ ] **Real-device testing completed:** 3 PASS rows out of 45 (TEST_MATRIX).

## Phase 8 operations

- [x] CI/CD workflows written (`.github/workflows/ci.yml`, `release.yml`, Dependabot, gitleaks).
- [x] CI green on GitHub: run 35894524054 on `7793a8a` (Flutter 196 tests, Kotlin + Robolectric tests, lint, debug builds, unsigned release APK with R8, gitleaks).
- [x] CHANGELOG.md with migration, security and rollback notes.
- [x] SECURITY.md, docs/PRIVACY.md, docs/SECURITY_RESPONSE.md, docs/DATABASE_MIGRATIONS.md.
- [ ] Release secrets configured in a protected `release` environment.
- [ ] Support contact published (SECURITY.md, store listing).

## Also needed before submission

- [ ] Final `applicationId` (currently the placeholder `com.safeguard.app`).
- [ ] Upload key created and backed up; Play App Signing enrolled.
- [ ] Accessibility declaration video recorded (docs/GOOGLE_PLAY.md §2).
- [ ] VPN declaration submitted (docs/GOOGLE_PLAY.md §1).
- [ ] Data safety form filled (docs/GOOGLE_PLAY.md §4).
- [ ] Target SDK meets Play's current requirement (check `flutter.targetSdkVersion` in the build output).
- [ ] Bundled-list provenance reviewed by the publisher (docs/LISTS.md).
- [ ] Internal testing track → closed beta with real testers → fix → production.
