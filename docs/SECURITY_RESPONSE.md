# Security response process

Applies to SafeGuard and any future update infrastructure. **Roles** (one
person may hold several in a small team, but *signer* ≠ *author* of the
fix):

- **Incident lead:** coordinates the response and makes the decisions.
- **Engineer:** writes the fix.
- **Reviewer:** reviews the fix and checks the tests.
- **Release signer:** holds the upload key, or the update-signing key in
  future.
- **Communications:** writes user-facing notes and store text.

## Severity

| Level | Examples | Target: fix released |
|---|---|---|
| Critical | Remote code execution; leak of logs or PIN material; protection silently off for everyone; signing key compromised | 72 h |
| High | Protection bypass available to any app without user action; crash loop that disables filtering; privacy leak through diagnostics | 7 days |
| Medium | Bypass needing device-owner actions not already documented; a false positive blocking a major service | 30 days |
| Low | Hardening, defence in depth | Next release |

## Standard lifecycle

**Detection → Assessment → Containment → Fix → Testing → Release → User
communication → Post-incident review**

1. **Detection.** Sources: private vulnerability reports, CI (gitleaks,
   tests), Play pre-launch reports, user feedback (Settings → Send
   feedback), store reviews. Log it in a private advisory with a
   timestamp.
2. **Assessment.** Reproduce it on a test device. Record the affected
   versions, the data at risk (see PRIVACY.md) and the severity. Check
   whether it's already known in THREAT_MODEL.md.
3. **Containment.** Stop the harm before the fix, for example: halt a
   staged rollout (Play Console), unpublish a bad update package, or tell
   users to use Safe Mode.
4. **Fix.** Make the smallest change that removes the cause. Add a
   regression test that fails without the fix.
5. **Testing.**
   - CI must be green: format, analyze, Flutter and Kotlin/Robolectric
     tests, lint, and a release build.
   - Run the relevant TEST_MATRIX rows on at least one real device.
6. **Release.** Bump PATCH (or MINOR). Add a CHANGELOG entry with
   *Security notes*. Tag, then the release workflow builds and signs. Use
   a Play staged rollout of 10 % → 50 % → 100 % unless the issue is
   Critical, which goes straight to 100 %.
7. **User communication.** Write store "What's new" text, plus an in-app
   note if user action is needed, and publish the GitHub advisory after
   users can update. State what was affected, what to do, and what wasn't
   affected. **Never** claim "fully secure".
8. **Post-incident review** within 2 weeks: timeline, root cause, why
   tests missed it, follow-up tasks, and updates to THREAT_MODEL.md and
   this document. Blameless.

## Playbooks

### Critical vulnerability in the app
Contain by pausing the staged rollout. If the flaw is in a feature that
can be turned off safely (e.g. the decision trace), tell users how to turn
it off until the fix lands. Then follow the standard lifecycle.

### Compromised rule package (future update server)
1. Stop serving the package and revoke it: publish a newer signed package
   that restores the previous content.
2. The client refuses downgrades, so the fix is always a *higher*
   version. `expiresAt` limits how long a bad package can stay active.
3. If the signing key is suspected, follow **Key compromise** below.
4. Clients keep blocking with the last valid package, or the APK's
   bundled lists, throughout.

### Harmful false positive (a legitimate domain blocked)
- **Workaround for users:** add the domain to Allowed domains (PIN).
- **Bundled list:** remove the entry in the list build
  (`DomainListBuildTest` / `LISTS.md`), add the domain to `NeverBlock` if
  it's critical infrastructure, and ship a PATCH release.
- **Future update server:** push a signed package without the entry
  (emergency path in SECURITY.md).

### AI model issue (bad classifications)
- Short term: users can switch AI off (PIN) or use Normal mode's higher
  thresholds. Rules keep working either way.
- Ship a model rollback: the previous model is bundled in a PATCH
  release, or delivered as a signed model update that passes the probe
  validation.
- Add the failing examples to the evaluation set before retraining.

### Privacy incident (data exposed or retained wrongly)
1. Identify what data, which versions, and whether it left the device.
   SafeGuard sends nothing itself, so check copy/export paths first.
2. Fix the whitelist or sanitiser. Add a test proving the field can't
   pass.
3. If stored data must be purged, ship a migration that deletes it on
   first start, and describe it in the CHANGELOG *Migration notes*.
4. Assess legal notification duties (e.g. GDPR 72 h) with counsel.
5. Tell users plainly what happened and what the update does.

### Backend compromise (future)
Assume anything on the host is readable. Signing keys must never be on
the host. Rotate every credential. Audit logs for unauthorised publishes.
Re-publish the last known-good signed packages. Clients reject unsigned
or downgraded content.

### Certificate or key compromise
- **Upload key:** request an upload-key reset from Google Play (Play App
  Signing), rotate the CI secrets and revoke the old ones.
- **Update-signing key (future):**
  1. Ship an app update that pins only the *next* key, which is already
     pinned as the second key.
  2. Publish all packages signed with it.
  3. Generate a new "next" key offline.
- **TLS certificate (future server):** revoke and reissue. Pins include a
  backup key, so clients keep working; rotate the pins in the next
  release.

## Contacts and records

- Private advisories: GitHub Security Advisories on this repository.
- Record decisions in the advisory. Summarise public items in
  CHANGELOG.md.
