# AI Content Shield (version 1.9.0+10)

The AI Content Shield is an extra protection layer on top of SafeGuard's
existing VPN/DNS filtering, search protection and policy engine. It
checks content shown inside **supported** Android apps and, when the
policy says so, gets it off the screen.

**What exists in this version, stated plainly:**

| Part | State |
|---|---|
| Text shown in supported apps → on-device text model → policy → skip/back/home | **Implemented**, unit-tested, built by CI. **Not tested on a real device.** |
| Screen images and video frames → on-device image model (GantMan MobileNetV2, LiteRT) → policy → skip/back/home | **Implemented**, built by CI. Model validated in Python on safe sample photos; the Kotlin preprocessing matches that validated reference exactly. **Not tested on a real device; accuracy on real content not measured.** |
| Screen capture (MediaProjection, Android's consent dialog) | **Implemented.** Needs the user's consent each session (Android 14+ asks again after a restart). |
| Apps: Instagram, TikTok, YouTube, Reddit, Facebook, Chrome, Firefox | **Supported by design, verified on no device.** Every app shows "Not tested on a device yet". |

Two optional switches (off by default; turning either off needs the PIN):

- **Check images in every app:** image checks run in any app in front,
  except system, phone, settings and launcher apps and SafeGuard itself.
  The accessibility service then receives events from every app, but only
  to know which app is in front. **Text is still read only in the
  supported apps.**
- **Maximum image sensitivity:** revealing images ("sexy" class, e.g.
  cleavage or swimwear) count as sexual in every mode. The SEXUAL
  threshold for images drops to 0.60, a single frame is enough (no
  confirmation), and frames are sampled every ~0.45 s instead of ~0.8 s.
  This **blocks more and makes more mistakes** (beach, sports, fitness,
  fashion photos). Category toggles and protection state still apply.

SafeGuard does not offer 100 % protection or 100 % detection. No
detection-and-block system is free of mistakes.

---

## 1. Architecture

```
Supported app (package id in SupportedApps)
  │                                   │
  │ AccessibilityEvent                │ MediaProjection frames (only after consent;
  │ (system-filtered to               │ only while a supported app is in front)
  │  supported packages)              ▼
  ▼                              ScreenCaptureService: 360 px RGBA, read in place
ContentShieldService                  │  FrameGate (≤ 1 frame/0.8 s, dHash same-screen skip)
  │ VisibleTextExtractor (text)       │  FramePreprocessor → 224×224 tensor (reused)
  ▼                                   ▼
ContentShieldEngine ── sg-text-1 (text) / GantMan MobileNetV2 via LiteRT (image)
  │  AiClassification {label, confidence, modelVersion}
  │  InferenceWatchdog · ShieldScores · TemporalConfirmer
  ▼
ProtectionDecisionEngine (existing, unchanged) ← the only authority
  ▼
ALLOW / UNKNOWN → nothing          BLOCK → BlockEscalation:
                                     1st: swipe to the next reel/post
                                     2nd (within 8 s): Back
                                     3rd: Home + "This content was blocked"
                                   + metadata-only log event
```

Code:
- Engine (no Android imports): `android/app/src/main/kotlin/com/safeguard/app/engine/shield/`.
- Android: `shield/ContentShieldService.kt` (text, gestures),
  `shield/ScreenCaptureService.kt` (frames), `ai/LiteRtImageRuntime.kt`.
- Wiring: `ProtectionManager`. UI: `lib/features/shield/`.

**The AI never decides alone.** `ShieldPolicy.decide` gives its scores to
the existing `ProtectionDecisionEngine`. That engine applies:
- protection on/off;
- category toggles;
- the mode thresholds (NORMAL 0.90, STRICT 0.70, CUSTOM);
- UNKNOWN for uncertain or unavailable results, never turned into BLOCK.

## 2. Labels and categories

| AI label | Policy category | Image model source |
|---|---|---|
| SAFE | — | `drawings` + `neutral` |
| SUGGESTIVE | SEXUAL, **STRICT mode only** | `sexy` (revealing / partial nudity, not pornographic) |
| SEXUAL | SEXUAL | `porn` + `hentai` |
| NUDITY | SEXUAL | (this model has no separate nudity class) |
| VIOLENCE, GORE, GAMBLING, DRUGS, DANGEROUS | same | text model only (the image model doesn't detect these) |
| UNKNOWN | — | top probability < 0.40 or model unavailable; never a block by itself |

For images the category evidence is the sum of its classes'
probabilities (softmax), e.g. SEXUAL = porn + hentai. Every result
carries the label, the model's own confidence and the model version
(`gantman-nsfw-mnv2@110`, `sg-text-1`).

**No skin-tone, colour or exposed-area heuristics are used anywhere.** The
image model is a semantic classifier (MobileNetV2 fine-tuned on labelled
images). Measured: a flat skin-coloured image scores SEXUAL 0.24 (§8b),
well below every threshold.

## 3. Temporal confirmation

`TemporalConfirmer` (window 5 s, 2 samples, instant bar 0.97):
- A clearly safe sample passes and ends any risky streak.
- A risk ≥ 0.97 passes: it can be blocked on the first frame.
- Otherwise the evidence is the minimum of the last two risky samples.
  Until there are two, the result is UNKNOWN (not blocked).

Spec example, STRICT: 0.55 → pending; 0.72 → evidence 0.55; 0.94 →
evidence 0.72 → **BLOCK** (tested). With frames every ~0.8 s, uncertain
content is blocked after about 1–2 s; obvious content on the first frame.

## 4. Model selection

### Text: `sg-text-1`

Trained in this repository on SafeGuard's own phrases (no third-party
data), pinned by SHA-256. See docs/PHASE_4_AI.md.

### Image: **GantMan nsfw_model v1.1.0, MobileNetV2 140/224**, chosen by the project owner

| Property | Value |
|---|---|
| File | `saved_model.tflite` from the official GitHub release 1.1.0 (`nsfw_mobilenet_v2_140_224.zip`), **unmodified**; stored as `assets/models/gantman-nsfw-mnv2.tflite` |
| Size / SHA-256 | 24,414,436 bytes / `6d9271fd927ef46328e8168babeaf4169abed8f5808d79383f448f90c67f36d4` (pinned in `BuiltInImagePacks`, verified before loading; test checks the asset) |
| License | MIT (Copyright (c) 2020 The nsfw_model Developers). Shown in the app's open-source licenses |
| Input / output | 224×224×3 float32 NHWC, RGB scaled to 0..1 / softmax over drawings, hentai, neutral, porn, sexy |
| Runtime | LiteRT (`com.google.ai.edge.litert:litert:1.4.0`), on device, offline, 2 threads |
| Reported accuracy | ≈ 92 % validation accuracy **on the authors' own data** (release `train_results.txt`); **not independently measured** |
| Training-data provenance | Web-scraped (the `nsfw_data_scraper` project: adult sites / Reddit). The consent of the people depicted and the copyright status of those images are unknown. **The project owner chose this model knowing this**; it is a legal and ethical risk to review before a store release |

Alternatives considered and why they weren't used: Marqo ViT-tiny
(Apache-2.0, binary, undocumented data) and the ViT-base / EVA models
(86 M parameters, too large). All of them are hosted on Hugging Face,
which this environment's network policy blocks, so they couldn't be
downloaded or verified. GantMan was reachable through GitHub.

## 5. Screen acquisition

| Mechanism | Used for | Notes |
|---|---|---|
| **AccessibilityService, package-restricted** | Text; foreground app; the skip/back/home actions | Events only from the 9 supported package ids (system filter, narrowed to the apps the user left on). `canPerformGestures` only for the single "next item" swipe. No accessibility screenshots |
| **MediaProjection** (`ScreenCaptureService`) | Screen frames for the image model | Android's consent dialog (whole screen on 14+); Android's capture indicator; a foreground notification. See below |
| `takeScreenshot()` / overlays | **Not used** | Silent capture / drawing over apps |

What the capture service does:
- **Frame size:** 360 px wide, aspect kept (e.g. 360×800), RGBA_8888.
- **Frame handling:** each frame is read in place from the ImageReader
  buffer (no bitmap, no copy), classified, then closed.
- **When frames are produced:** only while a supported, enabled app is in
  front and protection is on. Otherwise the virtual display is detached,
  so Android produces no frames at all.
- **When it stops:**
  - the user stops it in SafeGuard (PIN);
  - the user or Android stops it from the system UI;
  - protection or the shield is turned off.

  A pause only detaches the display. After a stop, new consent is needed.
- **Protected (DRM) video and FLAG_SECURE screens** come out black, so
  they can't be checked.

## 6. Privacy

- **On device only.** No upload; no cloud adapter.
- **Never stored:** screen frames, images, screen text or hashes of them.
  - Frames are released after inference.
  - The input tensor and LiteRT's input buffer are zeroed after each run.
  - Text is dropped and nodes are recycled.
- **Never read:** input fields, password fields, apps outside the list.
- **Logged on a block** (if the log is on): time, app package, category,
  confidence rounded down to 10 %, model version and the action taken
  (`ai_shield:<kind>:<label>:<model>:<skip|back|home>`).
- **Enforced by tests:** `ShieldSourceAuditTest` fails the build if the
  shield or capture code uses logging, file or preference writes, network,
  bitmaps or encoding, or if a permission other than the six listed is
  declared.

## 7. Performance and failure handling

| Concern | Mechanism |
|---|---|
| Continuous processing | Frames only in supported apps; `FrameGate` ≤ 1 per 0.8 s, skips unchanged screens; text ≤ 1 per s |
| Model loading | Once, on the first frame, from a memory-mapped uncompressed asset (no 24 MB heap copy); released when capture, the shield or protection stops |
| Slow device | `InferenceWatchdog`: 3 image runs over 1.5 s → image checks paused 60 s, status "too slow" |
| Model missing / corrupted / load failure / out of memory / wrong tensor shapes | `ImageModelState` → image UNAVAILABLE (UI says so); a transient failure is retried once; corrupted never |
| Consent refused or revoked | Status "image checks are off"; nothing captured |
| Block loops | 1.2 s per-app debounce; escalation skip → back → home |
| UI truthfulness | ACTIVE only when text **and** image checks run; otherwise PARTIAL / UNAVAILABLE with reasons |

**Measured, not on a phone:**
- Image model: 9.8 ms median per frame (Python LiteRT, 2 threads, desktop
  container CPU).
- Text model: 0.58 ms median (JVM).

**Not measured:** phone latency, battery, memory, thermal.

## 8. Measured quality

### 8a. Text (`ShieldTextEvalTest`, 66 hand-written EN/AR sentences)

| Group | n | Blocked NORMAL | Blocked STRICT |
|---|---|---|---|
| Safe (incl. beach, swim, medical, "shot", "killer workout") | 40 | 0 | 0 |
| News (war, crash, drug seizure, gambling law) | 5 | 0 | 0 |
| Risky | 21 | 13 | 16 |

Small, hand-written set: not a real-world rate.

### 8b. Image (Python, real model, safe sample photos from scikit-image)

| Photo | safe | sexual | suggestive |
|---|---|---|---|
| astronaut (person) | 0.86 | 0.08 | 0.06 |
| coffee | 0.88 | 0.09 | 0.03 |
| cat | 0.96 | 0.02 | 0.02 |
| rocket | 0.93 | 0.06 | 0.01 |
| camera (grey portrait) | 0.89 | 0.07 | 0.04 |
| horse | 0.74 | **0.21** | 0.05 |
| brick wall | 0.84 | 0.09 | 0.07 |
| flat skin-coloured image | ≈ 0.67 | 0.24 | 0.08 |

Values use the Kotlin-equivalent preprocessing on 360 px frames. The
Kotlin code is tied to this reference by golden values in
`ContentShieldTest.preprocessorMatchesTheValidatedReference`.

What this shows: the pipeline works end to end, and safe photos stay far
below the thresholds. What it doesn't show: detection accuracy on real
explicit content. No explicit images were used, deliberately. The only
accuracy figure is the authors' own ≈ 92 %.

### False-positive and miss risks

- **Images:** swimwear, beach, sports, fitness, breastfeeding, medical
  images, classical art, dark or skin-toned scenes (the horse photo
  reached 0.21). STRICT mode counts "sexy" (suggestive), so it will block
  some swimwear and fitness photos by design.
- **Misses:** small, partial or unusual explicit content; video moments
  between samples; anything the model wasn't trained on.
- **Not detected by images at all:** violence, gore, gambling, drugs,
  dangerous content. Only the text model covers those.

## 9. Android versions and requirements

- **Android versions:** minSdk 24.
  - MediaProjection works from Android 5; the foreground service type
    applies on Android 10+.
  - Android 14+ asks for consent every session.
  - Android 13+ may restrict accessibility for sideloaded builds.
- **Permissions added in 1.9.0:** `FOREGROUND_SERVICE` and
  `FOREGROUND_SERVICE_MEDIA_PROJECTION` (for the capture service). No
  storage, overlay or usage-stats permission.
- **APK size:** + 24.4 MB model; + the LiteRT native library per ABI.
- **RAM:**
  - model memory-mapped (24 MB, file-backed);
  - LiteRT working memory (not measured on a phone);
  - one 224×224×3 float tensor (0.6 MB);
  - 360 px frames in the ImageReader (2 × ≈ 1.1 MB).

## 10. Known limitations

- **Not tested on a real device:** no app has been checked on a phone
  (docs/FINAL_AI_TESTING.md).
- **Image model:**
  - Accuracy is not independently measured.
  - Its training-data provenance is questionable (owner-accepted).
  - It covers sexual/suggestive content only.
- **Content can be missed:**
  - Blocked content can be visible for about 1–2 s before the skip.
  - Frames are sampled, so short video moments can be missed.
  - DRM video and secure screens are black to capture.
- **Skipping depends on the app:** "skip" is an upward swipe; in apps or
  screens where that doesn't move to the next item, SafeGuard escalates to
  Back and Home.
- **Consent and the user's control:**
  - Android 14+ requires new capture consent after every restart; image
    checks are off until the user allows it again.
  - The device owner can stop capture, disable the accessibility service
    or uninstall.
- **Privacy note:** messages displayed in supported apps are processed in
  memory like any other content.
