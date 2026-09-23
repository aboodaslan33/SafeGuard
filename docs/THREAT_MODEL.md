# Threat model

Scope: SafeGuard 1.7.0 on an Android device the owner controls. No server
side exists.

## Assets

| Asset | Why it matters |
|---|---|
| Protection state (on/off, mode, categories, lists) | The product's purpose: someone may want to weaken it |
| PIN (hash, attempt counter) | Gates every loosening action |
| Local log and statistics | Can reveal what was blocked (sensitive browsing information) |
| User lists and keywords | Reveal preferences |
| DNS traffic seen by the VPN | Browsing metadata |

## Adversaries and what they can do

| # | Adversary | Goal | Mitigations | Residual risk |
|---|---|---|---|---|
| T1 | Device user trying to get around a parent's settings (physical access, no PIN) | Turn off filtering | PIN on every loosening action (PBKDF2, escalating lockout, monotonic clock); Protection Lock; interruption detection and log; Safe Mode needs the PIN | The owner of the Android settings can always disconnect the VPN, force-stop, clear data or uninstall. **Can't be prevented without device-owner / MDM, which SafeGuard deliberately doesn't use.** Clearing data resets the app (documented as the forgotten-PIN path) |
| T2 | Same user, brute-forcing the PIN | Find the PIN | 5 free tries, then 30 s → 1 h locks; counter in encrypted storage; corrupt counter = locked; clock changes ignored | Reboot + clock change can end one lockout early (documented); 4-digit PINs are weaker than 6 |
| T3 | Bypass by network configuration | Avoid DNS filtering | Private DNS (strict) detected and reported; other VPN detected; setup assistant explains fixes | Apps with built-in DoH/DoT or hard-coded resolvers, another VPN, Chrome Secure DNS: detectable only in part, **not preventable** by a VPN-DNS filter |
| T4 | Another app on the device (malware, no root) | Read SafeGuard data or control it | Private app storage; `allowBackup=false`; no exported components except launcher/boot (protected broadcasts); VPN/Accessibility services bound only by the system; channel only reachable from our own Flutter engine | A rooted device or OS exploit defeats app sandboxing (out of scope) |
| T5 | Someone with the unlocked phone, curious about history | Read the log | App lock (PIN on open); log retention setting incl. "none"; log holds blocked domains only, searches as 32-bit HMAC ids (Keystore key) | Blocked domains are visible to someone who knows the PIN |
| T6 | Network attacker (café Wi-Fi) | Tamper with DNS answers | Same exposure as without SafeGuard (plain DNS to the network's resolver); blocking decisions are local | SafeGuard doesn't add DNS encryption (possible future work) |
| T7 | Supply-chain / update attacker | Push malicious rules or a model | No remote updates exist; bundled assets are SHA-256-pinned; future updates designed with signatures (UPDATE_ARCHITECTURE.md) | Compromise of the build machine or signing key (standard release hygiene) |
| T8 | Crash-inducing inputs (malformed DNS packets, huge inputs) | Crash the VPN → no filtering | Bounds-checked DNS parser, pointer-hop limit, input length limits on the channel, loop failure → bounded recovery, DB errors fail closed (Phase 7) | Unknown parser bugs; no fuzzing campaign has been run |
| T9 | Privacy leak through diagnostics or logs | Exfiltrate browsing data | Diagnostics whitelist + token sanitiser; Android logs constant messages only (test-enforced); Flutter logs off in release | The user can paste diagnostics anywhere (by design, nothing personal is in them) |

## Phase 8 additions

| # | Surface | Risk | Mitigation | Residual |
|---|---|---|---|---|
| T10 | Update packages (future) | Malicious or corrupted rules/model; rollback to an old, weaker package; stale package forever | Pinned ECDSA keys (two for rotation), strict manifest schema, SHA-256 payload binding, full parse + probe before activation, monotonic versions, `expiresAt`, re-verification at load, APK fallback (`UpdateStore`, 15 tests) | No transport or keys yet. Key custody is a process matter (SECURITY.md) |
| T11 | Config backup file | Reading it reveals lists; tampering injects rules | App-private `noBackupFilesDir` (sandbox, never cloud-backed); every line re-validated on restore; restore only after a DB rebuild and only if no user rules exist; deleted by "Delete all data" | Rooted device can read it (same as the DB) |
| T12 | Crash reports, telemetry, feedback, decision trace | Leak of URLs, queries, tokens through error messages or free text | Messages never stored (type + app frames only); telemetry is a closed enum, off by default; trace has no subject field; feedback shows an exact preview and warns on links/emails/numbers; nothing is transmitted by the app | The user may paste the text anywhere (by design) |
| T13 | Notifications | Revealing browsing on the lock screen | The alert text is generic ("protection stopped / partial"). No domains, apps or queries | Visible on lock screen per system settings |
| T14 | Health monitor / recovery | Battery drain or restart loops | Backoff 1 → 4 → 16 min … 4 h, ≤ 6 attempts/day per component; VPN recovery ≤ 3 per 10 min; checks only while the VPN runs, Handler delays stretch under Doze | Not yet measured on a phone |
| T15 | Monetisation (future) | Protection disabled by a billing failure or spoofed entitlement | Protection features never gated (test-enforced); billing would require server-side verification | — |

## Trust boundaries

1. **Android OS ↔ SafeGuard:** trusted. SafeGuard relies on the sandbox,
   the Keystore and VpnService semantics.
2. **Flutter UI ↔ native engine (MethodChannel):** same process. Inputs
   are validated natively anyway (lengths, enums, domain syntax).
3. **VPN tun ↔ packet parser:** untrusted bytes. Parsed defensively.
4. **Bundled assets:** trusted after the SHA-256 check.

## Out of scope

- Rooted devices, custom ROMs, OS exploits.
- Preventing uninstall or data clearing. That needs device-owner APIs,
  which SafeGuard intentionally avoids (Play policy and user autonomy).
- Filtering inside apps' own encrypted traffic.
