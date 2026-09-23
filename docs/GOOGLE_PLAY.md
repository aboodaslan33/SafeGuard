# Google Play submission: technical material

Drafts for the Play Console forms and policy declarations. They describe
what the code in this repository does (version 1.9.0+10). Re-check them
against the final build before submitting. **Nothing here has been
reviewed by Google**, and approval is not guaranteed: VpnService and
Accessibility apps get extra review.

Wording rules for every form and listing: never "100% protection",
"blocks everything", "cannot be bypassed" or "undetectable". SafeGuard
does not hide itself, does not stop other VPNs, and cannot be made
impossible to uninstall.

---

## 1. VpnService declaration

Play policy allows `VpnService` for apps whose core functionality needs
it; "parental control / content filtering" is an accepted use when
declared. Declaration text:

> SafeGuard uses Android's VpnService to create a **local** VPN interface
> on the device. The interface routes only DNS requests (one route: a
> virtual DNS address) so SafeGuard can check requested domain names
> against the categories and block lists the user chose, and enforce
> SafeSearch. Other traffic doesn't pass through the app. No traffic is
> sent to a SafeGuard server (there is none). Allowed DNS requests are
> forwarded to the DNS servers of the user's current network; if the
> network reports none, 1.1.1.1 and then 9.9.9.9 are used as a fallback.
> The app does not collect or sell traffic data, inject ads, or
> redirect traffic for monetisation. Users see Android's system consent
> dialog, the VPN key icon, and can disconnect at any time in Android
> settings.

Facts behind the text (code references):

| Claim | Where |
|---|---|
| Only the virtual DNS address is routed | `SafeGuardVpnService.establish()`: `addRoute(VIRTUAL_DNS, 32)` |
| App excluded from its own VPN | `addDisallowedApplication(packageName)` |
| Forwarding to the network's DNS servers | `DnsForwarder` + `NetworkMonitor` (`LinkProperties.dnsServers`) |
| Consent through the system dialog only | `VpnService.prepare()` → `startActivityForResult` |
| No competing with other VPNs | `onRevoke()` stops; recovery never restarts after a revoke |
| Logs hold only blocked domains | `BlockLogger` records BLOCK decisions only |

## 2. Accessibility API declaration

SafeGuard sets `isAccessibilityTool=false`, so the Play Console
**Accessibility API permission declaration** is required, together with
the in-app **prominent disclosure** and **consent** that the app already
shows before sending the user to Android settings
(`app_protection_screen.dart`, `_AccessibilityDisclosure`).

Declaration text:

> SafeGuard's optional "App protection" feature lets the device owner
> choose apps that should not open (for example a game during study
> time). The AccessibilityService receives only TYPE_WINDOW_STATE_CHANGED
> events, with canRetrieveWindowContent=false, to learn the package name
> of the app that came to the foreground. When it is a protected app,
> SafeGuard returns to the home screen and shows its own "protected app"
> screen. It does not read screen content, text input, passwords,
> messages or notifications, does not perform gestures other than
> "Home", does not draw overlays, and sends no data off the device. The
> user enables it in Android's Accessibility settings after an in-app
> disclosure, and can turn it off there at any time.

Configuration: `res/xml/accessibility_service_config.xml`
(`typeWindowStateChanged`, `canRetrieveWindowContent="false"`,
`flagDefault`).

Video for the declaration (Play asks for one): record the disclosure →
Android Accessibility settings → enable → open a protected app →
"protected app" screen. **Not recorded yet.**

Note on sideloaded builds (Android 13+): Android restricts accessibility
for apps not installed from a store ("restricted settings"). The app
reports this as "unavailable" instead of failing silently.

## 2b. Accessibility API declaration: AI Content Shield (1.8.0)

A **second, separate** accessibility service
(`shield/ContentShieldService`, config `res/xml/content_shield_config.xml`)
with `canRetrieveWindowContent=true`. It is optional, off by default, and
turned on by the user after its own in-app prominent disclosure
(`content_shield_screen.dart`, `_ShieldDisclosure`). Play reviews content
retrieval by non-accessibility-tool apps strictly; this needs the
declaration and a video, and **approval is not guaranteed**.

Declaration text (draft):

> SafeGuard's optional "AI Content Shield" lets the device owner filter
> harmful content (sexual content, violence, gambling, drugs, dangerous
> content) shown inside a fixed list of apps: Instagram, TikTok,
> YouTube, Reddit, Facebook, Chrome and Firefox. The service is
> restricted to those package names. It reads the text those apps display
> on screen and classifies it **on the device** with SafeGuard's bundled
> model; when the user's protection settings say the content should be
> blocked, it performs one swipe to the next item, then "Back", then
> "Home" with SafeGuard's own "content blocked" screen. It never reads
> text input fields or password fields, never stores or transmits screen
> text, takes no screenshots, draws no overlays, and performs no other
> gesture. Only block metadata (time, app,
> category, rounded confidence, model version) is kept in the local log.
> The user turns it on in Android's Accessibility settings after an
> in-app disclosure, and can turn it off there at any time.

Facts behind the text: `packageNames` in the config (test keeps it equal
to `SupportedApps`), `VisibleTextExtractor` (skips editable/password),
`ShieldSourceAuditTest` (no logging, storage, network, capture or overlay
APIs in the shield path), `ContentShieldService.block` (Home + activity).

With the optional "check images in every app" switch, the service
receives events from all apps, but only to learn which app is in front
(for screen-capture image checks); window content is read only in the
supported apps. The declaration must say so if that option ships.

Video (not recorded): disclosure → enable in settings → open Chrome on a
page with blocked text → home + "content blocked" screen → log entry.

## 2c. MediaProjection (image checks, 1.9.0)

`ScreenCaptureService` (foreground service type `mediaProjection`) runs
only after the user taps "Turn on image checks" and accepts Android's
screen-capture dialog. Android shows its capture indicator, and SafeGuard
shows an ongoing notification. Frames (360 px wide) are classified on the
device by the bundled image model and released at once. Nothing is
recorded, saved or transmitted. Play's declaration for the
`FOREGROUND_SERVICE_MEDIA_PROJECTION` foreground-service type must
describe exactly this, with a video.

## 3. Permissions

| Permission | Why | Feature | Removable? |
|---|---|---|---|
| `INTERNET` | Forward allowed DNS queries | DNS filtering | No |
| `ACCESS_NETWORK_STATE` | Current network's DNS servers, online/offline | DNS filtering, health | No |
| `RECEIVE_BOOT_COMPLETED` | Restart protection after a reboot if it was on | Continuity | Possible, but weakens protection |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` (1.9.0) | Keep the user-approved screen capture running for image checks | AI Content Shield image checks | Yes: image checks are optional; the permission is unused unless the user starts them |
| `POST_NOTIFICATIONS` (runtime, Android 13+, optional) | One generic alert when protection stops or degrades | Alerts (Phase 8) | Yes: the alert is optional; without it, interruptions show when the app is opened |
| `BIND_VPN_SERVICE` (service) | Only the system can bind the VPN service | VPN | No |
| `BIND_ACCESSIBILITY_SERVICE` (service) | Only the system can bind the service | App protection | No (the feature itself is optional) |
| `<queries>` LAUNCHER / HOME / VIEW https | List launchable apps to choose from; open search results in a browser | App protection, search | Used instead of `QUERY_ALL_PACKAGES` |

The AI Content Shield's text checks use a second
`BIND_ACCESSIBILITY_SERVICE` service, bound only by the system.

Not requested: `QUERY_ALL_PACKAGES`,
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (the app opens the system list and
the user decides), storage, camera, contacts, location, SMS, call log,
`SYSTEM_ALERT_WINDOW`, `PACKAGE_USAGE_STATS`, device admin.

## 4. Data safety form (draft answers)

| Question | Answer | Basis |
|---|---|---|
| Does the app collect or share user data? | **No data collected or shared** (Play's definition: data transmitted off the device) | No analytics, crash reporting, accounts or servers |
| Is data encrypted in transit? | Not applicable (nothing is transmitted by the app, except DNS forwarding on the user's behalf, which is the network's normal DNS) | — |
| Can users request deletion? | Yes, in-app: Clear log, Delete all data; or Android "Clear data" | Settings → Privacy |
| Data processed only on the device | Web browsing (domain names checked on-device), app activity (foreground package name for protected apps), search text typed into SafeGuard's search screen, and (AI Content Shield, if the user turns it on) text and screen frames of the supported apps — processed in memory; only blocked domains / protected app names / 32-bit search hashes are stored locally | Play lets you declare on-device processing as not collected |

Play's guidance on "ephemeral on-device processing" should be re-read
before submitting: the DNS forwarding step sends the domain name to the
network's resolver, exactly as Android would without the app.

## 5. AI processing

- The text classifier is bundled in the APK (`assets/models/sg_text_v1.bin`,
  verified by SHA-256 before use) and runs on the device.
- It classifies only text submitted in SafeGuard's own search screen. It
  doesn't read other apps.
- Image checking is user-initiated (the system document picker). No
  image model ships in this version, so images are validated but not
  classified, and nothing is stored.
- A cloud adapter interface exists but **no cloud transport is compiled
  in**. Any future cloud use must be opt-in, disclosed and deletable
  (docs/PHASE_4_AI.md).
- Play's generative-AI policy doesn't apply: the app generates no content.

## 6. User controls

- Protection on/off (PIN), modes, categories, allow/block lists, keywords,
  protected apps.
- Log retention: 7 days / 30 days / none. Clear log. Export settings
  (file chosen by the user). Delete all data.
- Safe Mode (stops filtering at once if the internet breaks).
- PIN protection with escalating lockout; no remote control.

## 7. Target audience and content

- Audience: adults / parents managing their own or a family device.
  **Don't** list it in the "Designed for Families" programme without
  checking those extra requirements.
- Content rating questionnaire: utility, no user-generated content, no
  social features, no ads, no purchases.

## 8. Pre-submission technical checklist

See `RELEASE_CHECKLIST.md`. Key items: release AAB built with the upload
key (`docs/RELEASE.md`), `applicationId` final, privacy policy URL
hosted (text in `STORE_LISTING.md`), accessibility declaration video,
target SDK meets Play's current requirement (comes from Flutter's
`flutter.targetSdkVersion`; check it at build time).
