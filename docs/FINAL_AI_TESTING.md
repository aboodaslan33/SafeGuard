# AI Content Shield: manual test plan (real device)

**Status: NOT EXECUTED.** No scenario below has been run on a physical
device. The development environment has no Android device or emulator.
A scenario may be marked PASS only after it has actually been run on a
real phone, with the device, Android version, build and date recorded.

Build under test: 1.8.0+9, flavour `prod`, release build (debug builds
behave differently for R8 and performance).

Legend: `NOT EXECUTED` · `PASS` · `FAIL (details)` · `N/A (reason)`.

## 0. Setup (every run)

1. Install the release build from a store track (internal testing), not
   by sideloading. Android 13+ restricts accessibility for sideloaded apps.
2. Complete onboarding, set the PIN, and start protection (VPN on).
3. Open AI protection → AI Content Shield. Turn it on, read the disclosure,
   agree, and enable "SafeGuard AI Content Shield" in Android's
   Accessibility settings.
4. Check the screen reads **"Partially active"**:
   - text checks: Running;
   - image checks: Not running;
   - image model: Not included in this version.
   It must never read "Active".
5. Mode: test each app in NORMAL and again in STRICT.

Use **non-graphic, text-based** test material only: captions, titles
and web pages whose words are explicit. Do not open pornographic imagery
on a test device; image checks are not active in this version anyway.

## 1. Per-app content scenarios

Expected, for every app:
- **Safe content:** no block.
- **Clearly risky text:** block within about 1–3 s → home screen → "This
  content was blocked" with the category, and never the content itself.
- **Images and video without risky text:** not blocked (no image model).
  This is the expected, documented limitation, not a failure.

| # | App | Content | Expected | Result |
|---|---|---|---|---|
| A1 | Instagram | Normal feed, captions about sports/food/travel | No block | NOT EXECUTED |
| A2 | Instagram | Suggestive caption text | NORMAL: no block; STRICT: block only if the text model flags it | NOT EXECUTED |
| A3 | Instagram | Post whose caption is explicitly sexual | Block (SEXUAL) | NOT EXECUTED |
| A4 | Instagram | Violent / gory caption | Block (VIOLENCE/GORE) if the model flags it | NOT EXECUTED |
| A5 | Instagram | Gambling promo caption | Block (GAMBLING) | NOT EXECUTED |
| A6 | Instagram | Explicit image with neutral caption | Not blocked (no image model): documented limitation | NOT EXECUTED |
| A7 | Instagram | DM thread open | Nothing stored; no block unless displayed text is risky | NOT EXECUTED |
| T1 | TikTok | Normal For You feed | No block | NOT EXECUTED |
| T2 | TikTok | Video with explicit caption / on-screen text exposed as text | Block if exposed to accessibility | NOT EXECUTED |
| T3 | TikTok | Gambling / drug caption | Block | NOT EXECUTED |
| T4 | TikTok | Risky video without text | Not blocked: documented limitation | NOT EXECUTED |
| Y1 | YouTube | Home feed, normal titles | No block | NOT EXECUTED |
| Y2 | YouTube | Search results with explicit / gore titles | Block | NOT EXECUTED |
| Y3 | YouTube | Gambling video title | Block | NOT EXECUTED |
| C1 | Chrome | News site (war, crash reports) | No block (NORMAL) | NOT EXECUTED |
| C2 | Chrome | Casino landing page (if DNS lists didn't block it) | Block (GAMBLING) | NOT EXECUTED |
| C3 | Chrome | Page with explicit sexual text | Block (SEXUAL); DNS may block first | NOT EXECUTED |
| C4 | Chrome | Medical page (breast cancer screening) | No block | NOT EXECUTED |
| C5 | Chrome | Typing a risky word in the address bar | Not read (input field); search filter / DNS apply as before | NOT EXECUTED |
| F1 | Firefox | Same as C1–C4 | Same | NOT EXECUTED |
| R1 | Reddit | Normal subreddit | No block | NOT EXECUTED |
| R2 | Reddit | Post titles with explicit text | Block | NOT EXECUTED |
| R3 | Reddit | Violence / gore post titles | Block if flagged | NOT EXECUTED |
| X1 | WhatsApp (unsupported) | Any content | Never inspected (no events reach SafeGuard) | NOT EXECUTED |

## 2. Behaviour scenarios

| # | Scenario | Expected | Result |
|---|---|---|---|
| B1 | Switch between Instagram and Chrome quickly | No stale block carried to the other app; no crash | NOT EXECUTED |
| B2 | Fast scrolling in Reddit for 2 minutes | ≤ 1 text check per second; UI stays smooth; no block loop | NOT EXECUTED |
| B3 | Screen changes: rotate, split screen, picture-in-picture | No crash; checks continue | NOT EXECUTED |
| B4 | Network changes (Wi-Fi ↔ mobile, airplane mode) | Shield unaffected (on-device); VPN behaviour as before | NOT EXECUTED |
| B5 | Stop protection | No content read (state shows "protection off"); no blocks | NOT EXECUTED |
| B6 | Temporary pause (5 min) | No blocks during the pause; checks resume after it | NOT EXECUTED |
| B7 | Turn AI protection off (CUSTOM mode) | Shield "Unavailable: AI protection is off" | NOT EXECUTED |
| B8 | Turn the shield off in SafeGuard | PIN required; then no events delivered | NOT EXECUTED |
| B9 | Turn an app off in the shield list | PIN required; that app no longer checked | NOT EXECUTED |
| B10 | Turn the accessibility service off in Android settings | Screen shows "service is off"; nothing claims protection | NOT EXECUTED |
| B11 | Device restart | Shield resumes when Android rebinds the service; state correct | NOT EXECUTED |
| B12 | Battery: 1 h of mixed use of supported apps, shield on vs off | Battery difference recorded (no target yet) | NOT EXECUTED |
| B13 | Background: SafeGuard UI closed, OEM battery saver on (Infinix/XOS, Samsung) | Service keeps working or state shows the problem | NOT EXECUTED |
| B14 | Back gesture on the block screen (Android 13, 14, 16) | Goes home; the blocked content isn't shown again | NOT EXECUTED |
| B15 | Activity log after a block | Entry "Content Shield · category", app package only, no text | NOT EXECUTED |
| B16 | "Delete all data" | Shield off, log empty | NOT EXECUTED |
| B17 | Diagnostics copy | Shows shield state ids; no text or package lists | NOT EXECUTED |
| B18 | English UI | Shield screen and block screen fully in English, LTR | NOT EXECUTED |

## 3. Recording

For each run, add a row to `docs/DEVICE_TEST_LOG.md` with:
- device and Android version;
- build (version, flavour, release or debug) and date;
- the scenario ids;
- the result, with a screenshot of SafeGuard's own screens only (never of
  the tested content).

Set `SupportedApp.verifiedOnDevice = true` for an app only after its
scenarios pass on at least two devices.
