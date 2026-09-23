# AI Content Shield (final AI phase, version 1.8.0+9)

The AI Content Shield is an extra protection layer on top of SafeGuard's
existing VPN/DNS filtering, search protection and policy engine. It
checks content shown inside **supported** Android apps and, when the
policy says so, hides it behind SafeGuard's blocking screen.

**What works in this version, stated plainly:**

| Part | State |
|---|---|
| Text shown in supported apps → on-device text model → policy → block | **Implemented**, unit-tested, compiled for Android, built by CI. **Not tested on a real device.** |
| Screen images / video → on-device image model | **Not active.** No image model ships (see §Model selection). The full pipeline exists and is tested with a fixed-output test double, but the UI reports "Image model: not included" and the shield state is never "active". |
| Screen capture (MediaProjection) | **Not implemented on Android.** Designed (see §Screen acquisition); waits for an image model. No capture permission is declared. |
| Instagram / TikTok / YouTube / Reddit / Chrome / Firefox | **Supported by design, verified on no device.** Every app shows "Not tested on a device yet" in the UI. |

SafeGuard does not offer 100 % protection or 100 % detection, and does
not work in every app.

---

## 1. Architecture

```
Supported app (package id in SupportedApps)
  │  AccessibilityEvent (system-filtered to supported packages)
  ▼
ContentShieldService (Android)         ← content events only while active
  │  debounce 450 ms, FrameGate (≤ 1 sample/s, same-screen skip)
  ▼
VisibleTextExtractor                   ← skips inputs, passwords, codes,
  │  bounded walk, in memory             numbers, e-mails, links
  ▼
ContentShieldEngine (pure Kotlin, worker thread)
  │  on-device classifier (sg-text-1)  → AiClassification {label, confidence, modelVersion}
  │  InferenceWatchdog (slow → pause)
  │  ShieldScores                       → per-category evidence
  │  TemporalConfirmer                  → one uncertain sample never blocks
  ▼
ProtectionDecisionEngine (existing, unchanged)   ← the only authority
  │  protection on/off, category toggles, mode thresholds, UNKNOWN handling
  ▼
ALLOW / UNKNOWN (nothing happens)   BLOCK → Home + AppBlockedActivity (content variant)
                                          + metadata-only log event
```

The image path joins at the same point: `RgbaFrame` (capture buffer read
in place) → `FrameGate` with a perceptual hash → `ShieldImageClassifier`
(pinned `ImageModelPack`, SHA-256, load once) → the same scores,
confirmation and policy engine.

Code: `android/app/src/main/kotlin/com/safeguard/app/engine/shield/`
(engine, no Android imports), `…/shield/ContentShieldService.kt`,
`…/apps/AppBlockedActivity.kt`, `ProtectionManager` (wiring),
`lib/features/shield/` (UI).

### Why the AI never decides

`ShieldPolicy.decide` passes the AI's scores to the existing
`ProtectionDecisionEngine` exactly like search AI does. The engine
applies protection on/off, category toggles, the mode thresholds (NORMAL
0.90, STRICT 0.70, CUSTOM user values) and reports UNKNOWN for uncertain
or unavailable results. UNKNOWN is never turned into BLOCK (the conflict
policy that could do so is off in every shipped mode).

## 2. Labels and categories

| AI label | Policy category | Notes |
|---|---|---|
| SAFE | — | |
| SUGGESTIVE | SEXUAL | Counts only in STRICT mode (`ShieldScores.blockSuggestive`) |
| SEXUAL | SEXUAL | |
| NUDITY | SEXUAL | |
| VIOLENCE, GORE, GAMBLING, DRUGS, DANGEROUS | same name | |
| UNKNOWN | — | Model unsure or unavailable; never a block by itself |

- **Text** (sg-text-1): independent sigmoids per category. A category's
  evidence is its own score. The text model has no SUGGESTIVE or NUDITY
  output.
- **Images** (future pack): single-label softmax. A category's evidence is
  the sum of its labels' probabilities (SEXUAL + NUDITY, plus SUGGESTIVE in
  STRICT), which is the probability of that category.
- Every classification carries `label`, `confidence` (the model's output
  for that label) and `modelVersion`. The only derived number is a text
  model's SAFE confidence (product of `1 − risk`), flagged `derived=true`.

Skin-tone, colour or exposed-area heuristics are **not used anywhere**.
Sexual-content detection is left to a semantic model, which this version
has only for text.

## 3. Temporal confirmation

`TemporalConfirmer` (window 5 s, 2 samples, instant bar 0.97):
- A clearly safe sample (all risk < 0.50) passes through and ends any
  risky streak.
- A risk ≥ 0.97 passes through (blocked on the first sample).
- Otherwise, the evidence is the per-category **minimum** of the last two
  risky samples. Until there are two, the result is UNCERTAIN (UNKNOWN,
  not blocked).

Spec example, STRICT: 0.55 → pending; 0.72 → evidence 0.55; 0.94 →
evidence 0.72 ≥ 0.70 → **BLOCK**. In NORMAL the same sequence needs one
more sample ≥ 0.90 (tested in `ShieldPolicyTest`).

Latency cost: one extra sample (≈ 1 s with the gate) for uncertain
content; none for obvious content.

## 4. Model selection

### Text

`sg-text-1`, the Phase 4 model, is reused unchanged.
- **What it is:** logistic regression over hashed n-grams, 197,713 bytes.
- **Source:** trained in this repository on SafeGuard's own seed phrases,
  so there are no third-party weights or data (license: this repository's
  license).
- **Integrity:** the file's size and SHA-256 are pinned in
  `BuiltInModels`, and the file is verified before it is parsed.
- **Runtime:** on device, offline, pure Kotlin, so no runtime library is
  needed.

### Image: evaluated, **none bundled**

| Candidate | License | Size | Classes | Training data provenance | Verdict |
|---|---|---|---|---|---|
| GantMan nsfw_model (MobileNetV2) | MIT (repo notes "third-party copyrighted material under different licenses") | ≈ 9–17 MB | drawings, hentai, neutral, porn, sexy | Scraped adult-site/Reddit URLs (`nsfw_data_scraper`); consent of people depicted unknown | Rejected: legally questionable data provenance |
| Marqo/nsfw-image-detection-384 (ViT-tiny) | Apache-2.0 | 5.6 M params (≈ 22 MB fp32) | NSFW / SFW only | "Proprietary dataset of 220,000 images" incl. Rule 34 material; sourcing undocumented | Best size fit, but binary (can't separate SUGGESTIVE / SEXUAL / NUDITY), undocumented data, and **couldn't be downloaded or verified here** |
| Falconsai/nsfw_image_detection (ViT-base) | Apache-2.0 | 86 M params (≈ 340 MB) | normal / nsfw | "Proprietary dataset of 80,000 images" | Too large; binary; undocumented data |
| AdamCodd/vit-base-nsfw-detector | Apache-2.0 | 86 M params | sfw / nsfw | Not documented in detail | Too large; binary |
| Freepik/nsfw_image_detector (EVA02-base) | MIT | 86 M params | neutral / low / medium / high | 100,000 "synthetically labeled" images | Graded levels fit SAFE/SUGGESTIVE/SEXUAL best, but too large to bundle (APK is already ≈ 67 MB universal) |
| Zero-shot CLIP-style models (for violence/gore/gambling/drugs) | varies | ≥ 88 MB | any | OpenAI CLIP's model card puts deployed use out of scope; LAION-trained models have documented dataset problems | Rejected |

Decision:
- No candidate met all of these at once: clear commercial license, documented
  and lawful training data, mobile size, and categories beyond "NSFW". None
  covers violence, gore, gambling or drugs.
- Independently of that, this environment's network policy blocks
  Hugging Face downloads. So no weights could be fetched, hashed,
  converted, measured or evaluated here. Bundling a model that was never
  run would be faking it.

**No inference runtime is compiled in either.** ONNX Runtime's Android
package is 50 MB (≈ 12 MB per ABI). Adding it with no model would cost size
and permissions for nothing, and the right runtime depends on the model
that passes review. `ImageInferenceRuntime` is the integration point.

### How to add an image model later

1. Legal review of license and training-data provenance; pick the model.
2. Evaluate it on a lawful, labelled evaluation set, including the
   false-positive set in §8 (sports, beach, swimwear, medical, art,
   family photos).
3. Convert it to ONNX or TFLite and write its `sg-image-pack/1` manifest.
   That means labels mapped to `AiLabel`, input size, layout, mean/std,
   output kind, SHA-256 and size.
4. Pin the pack in `BuiltInImagePacks` and put the file in assets (or ship
   it through the signed update store, `kind=ai-model`).
5. Add the runtime dependency and a ~50-line `ImageRuntimeFactory`.
6. Implement MediaProjection capture (§5) and add its manifest entries:
   foreground service type `mediaProjection` and
   `FOREGROUND_SERVICE_MEDIA_PROJECTION`.
7. Update `SupportedApps.verifiedOnDevice` only after real-device runs
   (docs/FINAL_AI_TESTING.md).

## 5. Screen acquisition

| Mechanism | Used? | Why |
|---|---|---|
| **AccessibilityService, content retrieval, package-restricted** | **Yes (text)** | Least privilege for text. The system delivers events only from the listed supported packages (`packageNames`, also narrowed at runtime to the apps the user left on). A separate service from App Protection, so each permission is granted for its own purpose with its own disclosure. |
| MediaProjection (screen capture with system consent) | Designed, **not implemented** | The right mechanism for images: the user sees Android's consent dialog and the capture indicator. Pointless without an image model; implementing it would add a capture permission and a foreground service with nothing to feed. |
| `AccessibilityService.takeScreenshot()` (API 30+) | **No** | Captures silently, with no system indicator. That conflicts with "do not silently capture the screen". |
| Overlays (`SYSTEM_ALERT_WINDOW`, accessibility overlay) | **No** | Not needed: a block sends the user home and shows SafeGuard's own blocking activity. |

What the service does:
- **Events:** window-state, content-changed and view-scrolled events from
  supported packages only.
- **While inactive:**
  - shield off → no events at all;
  - protection off or paused → app switches only, and no content is read.
- **Snapshot:** 450 ms after the last event; `FrameGate` allows at most
  one per second, and at least one every 2.5 s while scrolling.
- **Reading text:** a bounded walk (≤ 400 nodes, depth ≤ 30,
  ≤ 2,000 characters) that skips editable fields, password fields and
  invisible nodes, and drops fragments that look like codes, numbers,
  e-mails or links.
- **Classification:** on a single background thread, while any sample
  still in progress is dropped.
- **Block:** home, then the "This content was blocked" screen (category
  only). A 3 s cooldown per app prevents block loops.

## 6. Privacy

- **On device only.** No upload, no cloud adapter registered. The Phase 4
  cloud interface still requires explicit consent and an encrypted
  transport, neither of which exists.
- **Never stored:** screenshots, images, screen text or its hashes.
  Temporary buffers are cleared after inference: the tensor is zeroed, the
  text is dropped, and nodes are recycled.
- **Never read:** input fields (messages being typed, search boxes,
  address bar), password fields, apps outside the supported list.
- **Logged on a block only, if the log is enabled:** timestamp, app
  package, category, confidence rounded down to 10 %, action, model
  version (`ai_shield:<kind>:<label>:<model>`). Retention follows the
  existing log setting ("don't keep a log" writes nothing).
- **Enforced by tests.** `ShieldSourceAuditTest` fails the build if the
  shield code uses logging, file or preference writes, network, screenshot,
  MediaProjection or overlay APIs, or if a permission is added.
- **Private messages:** messages *displayed* in a supported app (e.g.
  Instagram DMs) are visible text and are classified in memory like any
  other text, and not stored. This is disclosed in the app and in the
  disclosure sheet.

## 7. Performance and failure handling

| Concern | Mechanism |
|---|---|
| Continuous processing | Gate: ≤ 1 text sample/s, only after content changes in a supported app; same text is not re-classified |
| Budget | Separate `InferenceBudget` (60 text/min, the gate's maximum) so screen text never starves search; over budget → UNKNOWN |
| Slow device | `InferenceWatchdog`: 3 runs over 250 ms (text) / 1.5 s (image) → paused 60 s, status "inference slow" |
| Model loading | Text model loads once, lazily. Image model: once on first use, released when protection or the shield stops (`ContentShieldEngine.release`) |
| Memory | Bounded text; image frames are read in place from the capture buffer (≤ 4096 px per side) into one reused tensor |
| Model missing / corrupted / load failure / out of memory | `ImageModelState` NOT_BUNDLED / CORRUPTED / LOAD_FAILED / OUT_OF_MEMORY → image UNAVAILABLE; a transient failure can be retried; corrupted never |
| Classifier exception | Result UNAVAILABLE → UNKNOWN, never BLOCK |
| Accessibility off / unavailable / declined | Status UNAVAILABLE with the reason |
| Unsupported app | Never receives events (system filter) and `isActiveFor` is false |
| UI truthfulness | `ShieldStatusResolver`: OFF, PARTIAL (text only; the shipped best case), UNAVAILABLE. ACTIVE only if text **and** image run |

**Measured** (JVM in the build container, **not a phone**): sg-text-1 on
2,000 characters of page text, median 0.58 ms, p95 2.1 ms. Tree-walk
cost, battery and memory on a phone are **not measured**.

## 8. Measured text quality

`ShieldTextEvalTest` runs the shipped model through the real policy engine
on `page_text_eval_v1.tsv`: 66 original sentences in the style of captions
and headlines, English and Arabic. The safe ones deliberately share words
with risky categories: beach, swim, breast cancer screening, shot,
killer workout, pharmacy, museum, anatomy.

| Group | n | Blocked NORMAL | Blocked STRICT | UNKNOWN (NORMAL) |
|---|---|---|---|---|
| Safe | 40 | **0** | **0** | 13 (model unsure: low vocabulary coverage) |
| News (war, crash, drug seizure, gambling law) | 5 | 0 | 0 | 2 |
| Risky (sexual, gambling, drugs, violence, gore, dangerous) | 21 | **13** | **16** | 5 |

Reading:
- **No false positives on this set.** But the set is small and hand-written
  (it was written for this test, not sampled from real feeds), so this is
  not a false-positive rate for real use.
- **About 4 in 10 risky texts are missed in NORMAL.** For example:
  - "Hot girls sending nude pics…" scored 0.59;
  - "Buy guns without a license…" was classified safe;
  - an Arabic explicit-video caption was classified safe.
- **Text only.** Images and video, where most of this content is, are not
  checked at all in this version.

### False-positive risks (documented)

- **Text:** news about violence, drugs or gambling; medical and sexual-health
  education; song lyrics; slang. Mitigations: category toggles, the 0.90
  NORMAL threshold, two-sample confirmation, and the feedback/report flow.
- **Future image model:** beaches, swimming, sports, fitness, medical
  diagrams, classical art, breastfeeding and family photos are the known
  hard cases for NSFW classifiers. They must be in the image-model
  evaluation set before any model ships.

## 9. Android versions and requirements

- **Android versions:**
  - minSdk 24 (Android 7.0).
  - Accessibility content retrieval and runtime `packageNames` work on
    all supported versions.
  - Android 13+ may block accessibility for sideloaded builds
    ("restricted settings"); reported as unavailable.
  - Predictive back (Android 16) is handled on the blocking screen.
- **RAM:** text model ≈ 0.2 MB of weights plus a 64-entry score cache.
  Image path (future): one input tensor, e.g. 224×224×3 floats ≈ 0.6 MB,
  plus the model.
- **CPU:** one text classification per sample (sub-millisecond on a desktop
  JVM). Phone figures are not measured.
- **Permissions added:** none. The shield uses a second accessibility
  service (`BIND_ACCESSIBILITY_SERVICE`, bound by the system only). The
  manifest keeps exactly INTERNET, ACCESS_NETWORK_STATE,
  RECEIVE_BOOT_COMPLETED and POST_NOTIFICATIONS (test-enforced).

## 10. Known limitations

- **Coverage:**
  - Text only: photos, video, stories and reels are not inspected (no
    image model).
  - Apps may expose little text to accessibility (custom rendering, video
    feeds) or mark screens secure. App updates can change this at any
    time.
  - SafeGuard cannot guarantee inspection or blocking of every visual
    element in every Android app.
- **Blocking behaviour:** blocking sends the user to the home screen. It
  cannot hide one post in place (no overlay by design).
- **Model quality:** the text model is small and misses many risky texts
  (§8). It was trained on search phrases, not captions.
- **Privacy note:** messages displayed in supported apps are processed (in
  memory) like other text.
- **The user controls it:** the device owner can turn the service off in
  Android settings; SafeGuard reports it but can't prevent it.
- **Testing:** nothing in this document has been verified on a real
  device (docs/FINAL_AI_TESTING.md).
