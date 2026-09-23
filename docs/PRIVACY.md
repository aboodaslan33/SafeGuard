# Privacy model

SafeGuard is **local-first**: it filters on the device and stores
everything on the device. There is no SafeGuard server, account,
analytics SDK, crash SDK, advertising or tracking.

## What SafeGuard sees

| Layer | Sees | Doesn't see |
|---|---|---|
| VPN / DNS | Domain names the device looks up (e.g. `example.com`) and the query type | Page content, full URLs, cookies, passwords, messages, HTTPS/QUIC traffic, which app asked |
| Search protection | Text typed into **SafeGuard's own** search screen, in memory only | What you type in other apps or browsers |
| App protection (optional) | Package name of the app in the foreground | Screen content, text input, notifications |
| AI | Search text above (in memory); images you pick yourself (in memory, not saved) | Anything else |
| AI Content Shield (optional, off by default) | Text **shown** on screen in the supported apps you left on (Instagram, TikTok, YouTube, Reddit, Facebook, Chrome, Firefox); with "image checks" on (1.9.0, Android's capture consent), downscaled screen frames while those apps are open. Everything is classified in memory on the device and discarded. This includes messages *displayed* in those apps | What you type (input fields), password fields, any other app, protected (DRM) video. Frames are never saved, encoded or sent |

## What is stored (on the device only)

| Data | Contents | Retention | Controls |
|---|---|---|---|
| Protection log | Time, category, source, verdict, rule type; the blocked domain, or the protected app's package; for searches a 32-bit keyed hash instead of text | 7 days / 30 days (default) / none | Settings → Privacy: retention, clear |
| Statistics | Counts | Follows the log; lifetime counter | Clear log |
| Settings, lists, keywords, protected apps | What you configured | Until changed or deleted | Delete all data |
| Private config backup (`no_backup/user-config.bak`) | Your lists, keywords and protected apps, to survive a database rebuild | Until deleted | Deleted by "Delete all data" |
| PIN | Salted PBKDF2 hash, Keystore-encrypted | Until changed or deleted | Change PIN, Delete all data |
| Crash reports | Error type, the app's own stack frames, app / Android version, device model. **No error messages** | Latest 10 | Settings → Analytics and reports: off, copy, delete |
| Telemetry (opt-in, **off by default**) | Daily counts of fixed error types. No identifiers | 30 days | Same screen; turning it off deletes the counts |
| Decision trace (off by default) | Verdict, reason, category, pipeline stages. No domain or text | Memory only, last 50 | Diagnostics toggle; cleared when turned off |
| AI feedback | Category, source, rounded confidence, time | Cleared with the log | Clear log |
| AI Content Shield blocks | In the protection log: time, app package, category, confidence rounded to 10 %, model version. **No text, image or hash of either** | Follows the log | Same as the log; shield off in its screen (PIN) |

**Never collected:** passwords, PIN (only its hash), private messages,
photos, contacts, screenshots, screen or audio recordings, full browsing
history, full search history, authentication tokens, private app content,
location, advertising ID, device identifiers.

## What leaves the device

- **Nothing sent by SafeGuard itself.**
- Allowed DNS queries continue to the DNS servers of your current
  network, as they would without SafeGuard. If the network provides none,
  1.1.1.1 and then 9.9.9.9 are used.
- Diagnostics, crash reports and feedback leave the device **only if you
  copy or save them yourself**. Each screen shows exactly what's included
  first.
- Backups: app data is excluded from Android cloud backup and device
  transfer.

## Deletion

- Clear the log, change retention, delete crash reports, turn telemetry
  off (which deletes its counts).
- **Delete all data** (Settings → Privacy) removes the PIN, settings,
  lists, keywords, protected apps, log, crash records, telemetry and the
  private backup, and rotates the Keystore HMAC key.
- Uninstalling removes everything.

## Future features must keep these rules

- Cloud AI: opt-in per use, disclosed, encrypted, deletable, never the
  default (docs/PHASE_4_AI.md).
- Rule/model updates: anonymous GETs of signed public packages. No device
  ID and no reporting of what was blocked (docs/UPDATE_ARCHITECTURE.md).
- Telemetry transport: opt-in, sending only the `TelemetryReport` counts
  plus app/Android version. Never an install ID unless genuinely needed,
  and then resettable.
- Crash transport: opt-in, sending only `CrashRecord` fields.
