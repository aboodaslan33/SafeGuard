# Security

## Reporting a vulnerability

Please report privately, not in a public issue: use GitHub's **"Report a
vulnerability"** (Security → Advisories) on this repository, or the
security contact listed on the store page once published. Include the
app version (Settings → About) and, if useful, **Settings → Diagnostics →
Copy**, which contains no personal data.

We acknowledge reports within 3 working days and follow
[docs/SECURITY_RESPONSE.md](docs/SECURITY_RESPONSE.md). Please give us
reasonable time to release a fix before public disclosure.

| Version | Supported |
|---|---|
| Latest release (1.7.x) | ✅ security fixes |
| Older | ❌ update through the store |

## Security model (summary)

- **Local-first, no backend.** No account, server, analytics SDK, ads or
  trackers. The app makes no network requests of its own. The only
  traffic it forwards is the user's own DNS queries, to the network's
  resolver.
- **Least privilege.** The app uses 4 permissions (`INTERNET`,
  `ACCESS_NETWORK_STATE`, `RECEIVE_BOOT_COMPLETED`, optional
  `POST_NOTIFICATIONS`) plus system-bound VPN and accessibility services.
  It has no device admin and never uses root.
- **Secrets.**
  - The PIN is stored only as PBKDF2-HMAC-SHA256 (120k iterations, a
    per-PIN salt), encrypted with an Android Keystore key.
  - The event/cache HMAC key is a non-exportable Keystore key.
  - There are no secrets in the source, the APK or git.
- **Tamper resistance, honestly scoped.**
  - Loosening protection needs the PIN. Lockout escalates and ignores
    clock changes.
  - Interruptions are detected, logged and (optionally) notified.
  - The device owner can still disconnect the VPN, clear data or
    uninstall. SafeGuard doesn't pretend otherwise.
- **Untrusted input.** DNS packets are bounds-checked. Channel arguments
  are validated natively. SQL is parameterised. Update manifests follow a
  strict closed schema and need a signature.
- **Data minimisation.**
  - Logs keep only blocked domains, protected-app names and 32-bit
    search hashes, with retention of 7 or 30 days, or none.
  - Diagnostics, crash records, the decision trace and feedback all go
    through whitelists or sanitisers, and tests enforce it.
- **Builds.** R8 is on in release. Signing keys come from a gitignored
  `key.properties` or CI secrets. CI runs gitleaks on every push.

Details: [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) ·
[docs/PHASE_6_SECURITY.md](docs/PHASE_6_SECURITY.md) ·
[docs/PRIVACY.md](docs/PRIVACY.md).

## Key and secret management

| Secret | Where it lives | Who can use it |
|---|---|---|
| Play upload key | Offline backup + GitHub Actions secret `UPLOAD_KEYSTORE_BASE64` (with password secrets) in a protected `release` environment | Release workflow on tags only |
| Play app signing key | Google Play App Signing | Google |
| Update-signing keys (future) | Offline hardware token; the app pins the **public** keys (current + next) | Publisher's release engineer |
| PIN, HMAC key (per device) | Android Keystore on the user's device | The app on that device only |

Never commit `key.properties`, `*.jks` or `*.keystore`; they are in
`.gitignore`, and gitleaks scans every push.

## Future backend: secure administrative architecture (design only)

No backend exists. If one is added (for rule and model updates, security
advisories and emergency rule pushes), it must follow these rules:

- **No admin credentials in the app, ever.** The app only downloads
  **signed, public** packages anonymously. It has no write API and no
  account.
- **Signing is separate from hosting.** Packages are signed offline or in
  an HSM-backed signing service. A compromised web host can serve only
  what was already signed, and the client refuses downgrades and expired
  packages (`engine/updates`).
- **Roles:**
  - *rule editor*: proposes list changes;
  - *reviewer*: approves them, following the four-eyes principle;
  - *release signer*: signs a reviewed package; this is the only role
    with signing access, held by named people;
  - *operator*: manages infrastructure, with no signing access.
- **Authentication:** SSO with hardware-key MFA for every admin; no
  shared accounts; short-lived credentials.
- **Audit:** append-only logs of every rule change, approval, signing
  and publish, kept off the admin plane.
- **Emergency updates** (for example a harmful false positive) follow the
  same signing path with a fast-track reviewer. Each package carries an
  `expiresAt`, so a bad package stops being used automatically. The
  client also supports rollback and falls back to the rules in the APK.
- **Secrets management:** a managed secret store (cloud KMS or Vault);
  no secrets in code, CI logs or images; rotation documented.

## Monetisation (future) and entitlements

`lib/core/entitlements/plan.dart` defines Free and Premium, but **no
billing is implemented**. Protection features are never gated: a test
ensures the protection code doesn't import the plan code. If
subscriptions are added:

- Use Google Play Billing only.
- Verify purchase tokens on a server with the Play Developer API.
- Handle refunds, revocations, expiry and grace periods through Real-time
  Developer Notifications.
- Cache entitlements offline with an expiry. Never trust a client-only
  flag.
- A payment failure may remove only Premium conveniences, never safety
  features.
