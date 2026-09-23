# AI Content Shield: manual test plan (real device)

**Status: NOT EXECUTED.** No scenario below has been run on a physical
device. The development environment has no Android device or emulator.
A scenario may be marked PASS only after it has actually been run on a
real phone, with the device, Android version, build and date recorded.

Build under test: 1.9.0+10, flavour `prod`, release build (debug builds
behave differently for R8 and performance).

Legend: `NOT EXECUTED` · `PASS` · `FAIL (details)` · `N/A (reason)`.

## 0. Setup (every run)

1. Install the release build from a store track (internal testing), not
   by sideloading. Android 13+ restricts accessibility for sideloaded apps.
2. Complete onboarding, set the PIN, and start protection (VPN on).
3. Open AI protection → AI Content Shield. Turn it on, read the disclosure,
   agree, and enable "SafeGuard AI Content Shield" in Android's
   Accessibility settings.
4. Check the screen reads **"Partially active"** with text checks
   Running and image checks Off. It must not read "Active" yet.
5. Tap **Turn on image checks** → Continue → in Android's dialog choose
   **entire screen** → Start. Check:
   - Android's capture indicator appears;
   - a "SafeGuard is checking images" notification appears;
   - the shield now reads **"Active"**.
6. Mode: test each app in NORMAL and again in STRICT. STRICT also blocks
   revealing ("sexy") images.

Test material: use adult test content responsibly, on the owner's own
device, and never keep screenshots of it. Test safe content (beach,
sports, family photos) as carefully as unsafe content: false positives
matter.

## 1. Per-app content scenarios

Expected, for every app:
- **Safe content:** no block.
- **Clearly risky text or image:** within about 1–2 s SafeGuard swipes to
  the next item. If it's still on screen: Back, then Home with "This
  content was blocked" (category only, never the content).
- **Safe images (beach, sports, family):** no block in NORMAL; STRICT
  may block some swimwear or fitness photos (expected, but record it).

| # | App | Content | Expected | Result |
|---|---|---|---|---|
| A1 | Instagram | Normal feed, captions about sports/food/travel | No block | NOT EXECUTED |
| A2 | Instagram | Suggestive caption text | NORMAL: no block; STRICT: block only if the text model flags it | NOT EXECUTED |
| A3 | Instagram | Post whose caption is explicitly sexual | Block (SEXUAL) | NOT EXECUTED |
| A4 | Instagram | Violent / gory caption | Block (VIOLENCE/GORE) if the model flags it | NOT EXECUTED |
| A5 | Instagram | Gambling promo caption | Block (GAMBLING) | NOT EXECUTED |
| A6 | Instagram | Reel with nudity / explicit image, neutral caption | Skipped to the next reel (image model) | NOT EXECUTED |
| A8 | Instagram | Beach / swimwear / gym photos | NORMAL: no block; STRICT: may skip (record which) | NOT EXECUTED |
| A7 | Instagram | DM thread open | Nothing stored; no block unless displayed text is risky | NOT EXECUTED |
| T1 | TikTok | Normal For You feed | No block | NOT EXECUTED |
| T2 | TikTok | Video with explicit caption / on-screen text exposed as text | Block if exposed to accessibility | NOT EXECUTED |
| T3 | TikTok | Gambling / drug caption | Block | NOT EXECUTED |
| T4 | TikTok | Explicit or nude video without text | Skipped to the next video | NOT EXECUTED |
| Y1 | YouTube | Home feed, normal titles | No block | NOT EXECUTED |
| Y2 | YouTube | Search results with explicit / gore titles | Block | NOT EXECUTED |
| Y3 | YouTube | Gambling video title | Block | NOT EXECUTED |
| Y4 | YouTube | Shorts with nudity | Skipped to the next short | NOT EXECUTED |
| Y5 | YouTube | Normal video page showing explicit frames | Back (skip swipe doesn't change the video), then Home | NOT EXECUTED |
| FB1 | Facebook | Normal feed | No block | NOT EXECUTED |
| FB2 | Facebook | Reels / posts with nudity | Skipped; Back / Home if it stays | NOT EXECUTED |
| FB3 | Facebook Lite | Same as FB1–FB2 | Same | NOT EXECUTED |
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
| B19 | Image checks after a device restart (Android 14+) | Image checks off; turning them on asks Android's dialog again | NOT EXECUTED |
| B20 | Stop image checks in SafeGuard | PIN required; indicator and notification disappear | NOT EXECUTED |
| B21 | Stop casting from Android's quick settings / indicator | SafeGuard shows image checks off; no crash | NOT EXECUTED |
| B22 | Leave supported apps (home screen, WhatsApp) | No frames processed (battery); indicator may stay (Android) | NOT EXECUTED |
| B23 | Skip loop | A blocked reel followed by more blocked reels: skip, Back, Home, no endless swiping | NOT EXECUTED |
| B24 | Battery with image checks on, 1 h of reels | Record battery % and phone temperature | NOT EXECUTED |
| B25 | Netflix-style protected video in Chrome | Black frames, no block, no crash | NOT EXECUTED |

## 3. Recording

For each run, add a row to `docs/DEVICE_TEST_LOG.md` with:
- device and Android version;
- build (version, flavour, release or debug) and date;
- the scenario ids;
- the result, with a screenshot of SafeGuard's own screens only (never of
  the tested content).

Set `SupportedApp.verifiedOnDevice = true` for an app only after its
scenarios pass on at least two devices.
