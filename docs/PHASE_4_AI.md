# Phase 4 — AI Content Classification

## 1. Architecture (written before implementation; step 6/7 order corrected during implementation)

### Where AI plugs in

Phase 3 already had one seam built for this: `SearchClassifier` /
`SearchFilterService` in `engine/search/`, plus the reserved
`EventSource.AI`. The DNS path (`RuleEngine.DomainClassifier`) is **not**
used for AI: it runs on every lookup of every app, a domain name carries
little text, and a false positive there breaks whole sites. AI therefore
runs only **on demand**:

| Entry point | When | Input |
|---|---|---|
| SafeGuard search box | once per submitted query (never per keystroke) | query text, in memory only |
| "Check an image" | when the user picks an image in the system picker | image bytes, in memory only |

Nothing watches the screen, other apps, notifications or video.

### Pipeline

```
Content (text | image)
  → Preprocessing        text: SearchNormalizer → hashed n-gram features
                         image: header check → bounded decode → resize → normalise
  → ContentClassifier    (AdapterContentClassifier → first available ClassifierAdapter)
        LocalTextClassifierAdapter   on-device, shipped
        LocalImageClassifierAdapter  on-device pipeline; model runtime pluggable
        CloudClassifierAdapter       disabled: needs consent + encrypted transport (none shipped)
        MockClassifierAdapter        test sources only
  → ClassificationResult  multi-label scores per category (+ SAFE), status OK/UNCERTAIN/UNAVAILABLE/REJECTED
  → ProtectionDecisionEngine  rule signal + AI result + user settings + source
  → ALLOW | BLOCK | UNKNOWN
  → privacy-safe event / counters (no content)
```

All of this is pure Kotlin under `engine/ai/` (JVM-testable) except the
Android bitmap decoder and the image picker.

### Decision policy (`ProtectionDecisionEngine`)

First match wins:

1. Protection off → ALLOW.
2. User allowlist → ALLOW (explicit intent).
3. Known blocking rule (domain list, search lexicon) in an enabled
   category, or a user blocklist entry → **BLOCK** (AI is not consulted).
4. AI off → ALLOW (Phase 3 behaviour).
5. AI unavailable / input rejected → UNKNOWN.
6. Model uncertain (input mostly unknown to the model) → UNKNOWN, even
   with a high score.
7. Enabled categories whose score ≥ threshold → BLOCK on the highest one;
   all exceeded categories are reported (multi-label). Conflict: if a
   built-in SAFE rule matched, `ConflictPolicy.safeRuleWinsOverAi`
   (default **true**) keeps it allowed.
8. Highest enabled score in the uncertain band (≥ 0.5, < threshold) → UNKNOWN.
9. Otherwise → ALLOW (SAFE).

UNKNOWN never blocks in NORMAL mode. `blockUnknown` exists in the policy
for a future Strict option; nothing in the UI sets it.

### Thresholds and modes

| Category | NORMAL | STRICT |
|---|---|---|
| Sexual | 0.90 | 0.70 |
| Violence | 0.90 | 0.75 |
| Gore | 0.85 | 0.65 |
| Gambling | 0.90 | 0.70 |
| Drugs | 0.90 | 0.70 |
| Dangerous | 0.90 | 0.75 |

CUSTOM: the user sets each value, clamped to 0.50–0.99. These are
starting points, not tuned optima; they are data, not code.
Loosening (AI off, STRICT → NORMAL, any threshold raised) requires the
PIN. Tightening does not. Categories are the same toggles as DNS and search.

### Models

- **Text**: a small multi-label logistic-regression model (one sigmoid per
  risk category) over hashed word/bigram/char-n-gram features. Trained in
  this repository, deterministically, from a seed set written for this
  project (no third-party data). Shipped as an APK asset, SHA-256 pinned in
  code.
- **Image**: the full input pipeline ships, but **no image model is
  bundled** (see §License). The adapter reports UNAVAILABLE and the UI says
  so. A model is added by placing it in assets and adding a pinned
  `ModelSpec` + an `ImageModelRuntime`.
- Only models listed in the compiled manifest can load; the file's size
  and SHA-256 must match before parsing. Model files are data (weights);
  nothing is executed from them. No loading from storage or network.

### Performance limits

On demand only; LRU cache of scores (keyed by an HMAC of the input, not
the text); rate limit per minute; image byte/pixel limits and sampled
decoding; buffers cleared and bitmaps recycled after use. `VideoSampler`
is a plan-only interface (fixed interval, frame cap, early stop), not wired.

### Privacy

Stored: timestamp, source, category, action, confidence, rule type,
subject = `model id#keyed short hash`; aggregate counters (detections,
blocks, false-positive reports, per category); feedback rows
(timestamp, source, category, confidence, verdict). Never stored or sent:
text, images, thumbnails, features, embeddings.

## 2. What was implemented

| Deliverable | Where | Status |
|---|---|---|
| `ContentClassifier` (`classifyText`, `classifyImage`, `classifyContent`) | `engine/ai/ContentClassifier.kt` | Done |
| `ClassifierAdapter` + `AdapterContentClassifier` (routing, local first) | same | Done |
| `LocalTextClassifierAdapter` + shipped model `sg-text-1` | `engine/ai/text/`, `assets/models/sg_text_v1.bin` | Done, wired into search |
| `LocalImageClassifierAdapter` (validate → decode → resize → normalise → infer → release) | `engine/ai/image/ImagePipeline.kt`, `ai/BitmapImageDecoder.kt` | Pipeline done; **no image model** |
| `CloudClassifierAdapter` (consent + encryption gate, no transport) | `engine/ai/ClassifierGuards.kt` | Gate only; not registered in the app |
| `MockClassifierAdapter` | `src/test/.../ai/MockClassifierAdapter.kt` | Test sources only |
| `ProtectionDecisionEngine`, `ConflictPolicy`, `RuleSignal` | `engine/ai/ProtectionDecisionEngine.kt` | Done |
| Thresholds + NORMAL / STRICT / CUSTOM | `ThresholdProfiles`, `AiSettings` | Done; PIN for loosening in the UI |
| Text AI after the rule engine | `engine/ai/AiSearchFilterService.kt` | Done |
| Image check (system picker, in memory) | `ProtectionChannel.checkImage`, AI screen | Done; reports "no model" |
| Cache, rate limit | `GuardedContentClassifier`, `InferenceBudget` | Done |
| `VideoSampler` | `engine/ai/video/VideoSampler.kt` | Interface + plan only, not wired |
| Privacy-safe events, AI statistics, false-positive reports | `SearchEventRecorder`, `AiStats.kt`, `SqliteAiStatsStore`, DB v3 | Done |
| AI settings UI, "report incorrect block" | `lib/features/ai/`, block screen, activity log | Done |

### Search path now

```
submitted query
 → RuleBasedSearchClassifier + SearchPolicy (Phase 3, unchanged)
     BLOCK → done (event source SEARCH, rule id + hash); model not run
 → AI on? → GuardedContentClassifier (cache / rate limit)
          → LocalTextClassifierAdapter (sg-text-1)
          → ProtectionDecisionEngine (thresholds of the chosen mode)
     BLOCK   → event source AI, subject "sg-text-1#<keyed hash>", rule type ai_text
     UNKNOWN → allowed (not logged)
     ALLOW   → allowed (not logged)
```

## 3. The text model (`sg-text-1`)

- **Type:** multi-label logistic regression, 6 independent sigmoids
  (sexual, violence, gore, gambling, drugs, dangerous). SAFE = product of
  (1 − p). Features: word unigrams (plus Arabic prefix-stripped forms),
  word bigrams, character 3/4-grams; FNV-1a hashed into 8192 dimensions;
  L2-normalised.
- **Data:** `android/app/src/test/resources/ai/text_seed_v1.tsv`, 430
  short search-style phrases (English and Arabic) written for this
  project: 58 sexual, 40 violence, 34 gore, 39 gambling, 40 drugs, 39
  dangerous, 8 multi-label, 172 safe (including look-alikes: "sex
  education", "breast cancer", "gore-tex", "kill process linux",
  "suicide hotline", "علاج الادمان"…).
- **Training:** `TextModelTrainer` (test sources, not shipped):
  deterministic full-batch gradient descent, 2000 epochs, lr 4.0, L2 1e-5,
  positive weight √(neg/pos). `TextModelBuildTest` retrains it and checks
  that the shipped file is byte-identical and matches the pinned SHA-256.
  Regenerate with `SG_WRITE_MODEL=1` after editing the seed set, then
  update `BuiltInModels.TEXT_V1`.
- **File:** 197,713 bytes, SHA-256
  `59fdfef5a1110e9b917b7e142a75b6562681b33f46337941c03855e3ba7304c1`.
- **Uncertainty:** if fewer than 34 % of the query's words were seen in
  training, the result is UNCERTAIN → UNKNOWN (never blocks).

### Measured quality (held-out, honest numbers)

Every 5th seed example was held out and the model retrained on the rest
(`TextModelBuildTest.heldOutEvaluation`). 86 held-out phrases, 34 of them
safe:

| Threshold | Label recall | Wrong labels | Safe phrases flagged | Rules **+** AI caught (of 52 risky) |
|---|---|---|---|---|
| 0.50 | 0.37 (20/54) | 6 | 2 | 29 |
| 0.70 (≈ STRICT) | 0.30 (16/54) | 3 | 0 | 27 |
| 0.85 | 0.19 (10/54) | 0 | 0 | 23 |
| 0.90 (NORMAL) | 0.19 (10/54) | 0 | 0 | 23 |

What this means:

- The model is **conservative**: at NORMAL thresholds it produced no false
  positives on the held-out safe phrases, but it recognises only about one
  in five risky phrases *that it has not seen*. It works well on phrasing
  close to its seed set (see `LocalTextModelTest`) and poorly beyond it.
- Together with the Phase 3 rule layer, 23–29 of 52 held-out risky phrases
  are caught. The rest pass.
- 86 examples is a small evaluation set; these numbers have wide error
  bars and say nothing about real search traffic.
- **The seed set is the limiting factor**, not the model code. A larger,
  properly licensed and reviewed dataset is needed before the thresholds
  mean what their names suggest.

## 4. Images

The pipeline is complete and tested with a fake decoder and runtime:

1. Size limit (15 MB) before anything else.
2. Type from magic bytes (JPEG, PNG, WebP only); a declared MIME type
   that disagrees is rejected. GIF, BMP, HEIC, PDF, scripts etc. are
   rejected.
3. Dimensions read from the header with bounds-checked parsing (JPEG
   marker walk capped, no loops); max 16,384 px per side, 50 MP.
4. Power-of-two subsampling so the decoded bitmap is close to the model's
   input size (a 4000×3000 photo decodes to ~1000×750 for 224 px input),
   and the decoded buffer is checked against a 16 MB budget *before*
   decoding. On Android the platform's bounds must match our header.
5. Area-averaged resize to the model size, alpha composited on white,
   per-channel normalisation (NHWC float).
6. Inference through `ImageModelRuntime`.
7. The bitmap is recycled and pixel/tensor buffers are zero-filled in
   `finally`/`use` blocks, on success and on failure (tested).
8. Nothing is written to disk. The picker grants access to one file; no
   storage permission.

**No image model ships.** `LocalImageClassifierAdapter` is registered with
no runtime, so the app validates the picked image and reports
"classification unavailable (no model)". See §9 for why.

## 5. Privacy-safe logging

| Stored | Where | Never stored |
|---|---|---|
| Block event: time, source (SEARCH/AI), category, action, confidence, rule type (`keyword`/`ai_text`/`ai_image`), subject `rule-or-model-id#8-hex keyed hash` | `block_events` | query text, image bytes, thumbnails, features, scores of allowed content |
| Counters: AI detections, AI blocks, false-positive reports, per category | `counters` (`ai_*`) | which content was detected |
| False-positive report: time, source, category, confidence (2 decimals), verdict | `ai_feedback` (max 500 rows) | the content, the event subject |

Allowed and UNKNOWN results create no event. The in-memory score cache is
keyed by an HMAC of the content (per-install key). "Clear log" and "Erase
all data" clear AI counters, reports and the cache. Nothing is sent
anywhere: there is no network code in `engine/ai`, and the cloud adapter
has no transport and is not registered.

## 6. Tests

### Kotlin (JVM) — 83 new, 90 existing unchanged

| Class | Tests | Covers |
|---|---|---|
| `DecisionEngineTest` | 26 | every category BLOCK at high confidence; SAFE; spec example 0.97 @ 0.90; low confidence → UNKNOWN; inclusive, per-category thresholds; UNCERTAIN; unavailable/rejected; blockUnknown hook; multi-label; disabled category detected-not-blocked; NORMAL/STRICT/CUSTOM (clamp, NaN); loosening detection; protection off; AI off; rule wins without AI; disabled-category rule; explicit block/allow; SAFE rule vs AI (configurable); determinism; UNKNOWN category |
| `LocalTextModelTest` | 7 | shipped model recognises each category (EN/AR); safe look-alikes not blocked; unknown words UNCERTAIN; multi-label scores; STRICT vs NORMAL; empty input; stable hashing |
| `ModelIntegrityTest` | 7 | pinned SHA-256; tampered, truncated, padded, missing file refused; only manifest models; malformed/NaN model rejected; integrity failure → unavailable; no image model bundled |
| `TextModelBuildTest` | 3 | shipped model reproducible byte-for-byte from the seed set; held-out evaluation; seed-set sanity |
| `ClassifierRoutingTest` | 4 | routing by kind; swappable adapters; crash → UNAVAILABLE; no text in `toString` |
| `CloudAdapterTest` | 3 | never used without consent; needs current disclosure + encryption; local preferred, remote skipped unless allowed |
| `GuardsTest` | 3 | cache; failures not cached; rate limit → UNKNOWN, recovers |
| `AiSearchIntegrationTest` | 6 | rule block without running AI; AI blocks unseen query; UNKNOWN/low confidence allowed and not logged; AI off; real model end-to-end; disabled-category detection counted |
| `FalsePositiveTest` | 2 | report has only the allowed fields, rounded; per-category counts; clear |
| `ImagePipelineTest` | 18 | format sniffing; GIF/BMP/PDF/script rejected; empty; MIME mismatch; malformed PNG/JPEG; pathological JPEG terminates; large file; huge dimensions / decompression bomb; subsampling + decoded budget; multi-label result; memory released on success and on inference failure; decoder failure; NaN/short model output; no model; preprocessing math |
| `VideoSamplerTest` | 3 | interval + cap; invalid plans; early stop, frames closed |
| `AiBenchmarkTest` | 1 | §7 |

`SqliteStoresTest.aiCountersAndFeedbackStayApartFromBlockTotals`
(Robolectric) was **written but not executed** here (needs the Android
SDK). Its SQL was run against SQLite 3.45 separately.

### Flutter — 21 new (`test/features/phase4_test.dart`), 93 existing unchanged

Channel contract (settings, statistics, report carries no content, image
"no model", typed errors); `AiSettings` thresholds, clamping, loosening,
defensive parsing; controller sync; screens: AI blocks an unseen search
and the block can be reported (query not in the log), rule-blocked search
report can be cancelled, AI off, NORMAL vs STRICT, disabling AI needs the
PIN (cancel works; re-enable needs none), STRICT→NORMAL needs the PIN,
custom threshold editor, image check without a model, rejected and
blocked image results with report, statistics show counts only. Layout
test covers `/ai-protection` and the report button at 5 sizes × 2 text
scales.

## 7. Benchmark

Measured by `AiBenchmarkTest` on the **build container's JVM** (JDK 21,
4 vCPU, x86-64). These are not phone numbers; phones are typically
several times slower.

| Measurement | Result |
|---|---|
| Text model file | 197,713 bytes |
| Heap after loading the text model | ~194 KiB |
| Load + SHA-256 verify + parse (once, lazily) | ~1.1 ms median |
| Text classification per query (normalise + features + 6 sigmoids) | ~30–33 µs median |
| Image preprocessing 1000×750 → 224×224×3 | ~7.5–8.6 ms median |
| Image buffers at that size | 2.9 MiB decoded ARGB + 0.6 MiB tensor |

**Not measured:** anything on an Android device (no device here),
Bitmap decoding time, image inference (no model), CPU %, battery.
Rough reasoning only: AI runs once per submitted search or picked image,
never in the background, so idle CPU and battery cost is zero by design;
a search adds on the order of tens of microseconds (JVM) of work.

## 8. Security review

| Item | Finding |
|---|---|
| Model integrity | Size + SHA-256 checked (constant-time compare) before parsing; tampering tested. |
| Untrusted model loading | Only `BuiltInModels` entries, only from APK assets; no path, URL or storage input reaches the loader. |
| Arbitrary execution | Models are float arrays parsed by our own code; no reflection, class loading, native libraries, or interpreters. |
| Model parser | Strict: magic, version, dimensions, label ids, exact size, finite values. |
| Image input | Magic-byte typing, size/dimension/decoded-memory limits before decode, bounded header parsing, platform bounds cross-check. |
| Memory | Subsampled decode; bitmap recycled and buffers cleared in `finally`/`use`; `OutOfMemoryError` becomes a rejection. |
| Picker | `ACTION_OPEN_DOCUMENT`; read access to one file; stream read with a hard cap; no storage permission. |
| Storage | Model inside the APK (read-only). No images written. DB is app-private and excluded from backup (unchanged). |
| Permissions | No new permission; manifest unchanged. |
| Logging | No new `Log.*` calls; nothing content-derived is logged. |
| Network | No network code in Phase 4. |

## 9. Model licences and choices

| Model | Licence | Decision |
|---|---|---|
| `sg-text-1` (this repo) | Original work of the SafeGuard project, trained on project-written phrases; no third-party weights or data. The repository has **no LICENSE file**; the owner should add one. | Shipped |
| Falconsai/nsfw_image_detection (Hugging Face) | Hub metadata: Apache-2.0 | Not bundled: ~86M-parameter ViT (hundreds of MB, far too large for an APK and slow on phones), sexual-only (no violence/gore/…), training data provenance not documented on the model card |
| AdamCodd/vit-base-nsfw-detector (Hugging Face) | Hub metadata: Apache-2.0 | Not bundled: same size/scope/provenance concerns |

Licence tags were read from Hugging Face metadata on 2026-09-23; they were
not independently verified against the full model cards or the licences
of the underlying training data. Before adding any image model: confirm
the licence of the weights *and* the training data, obtain a small
quantised on-device variant (e.g. TFLite/LiteRT int8), add its runtime
dependency, pin its SHA-256 in `BuiltInModels`, and implement
`ImageModelRuntime`.

## 10. Known limitations

- The text model is small and trained on 430 phrases; held-out recall at
  NORMAL is about 0.19. It supplements the rule layer; it does not replace
  human-curated lists and cannot be relied on to catch new phrasing.
- Scores are not calibrated probabilities; "0.90" does not mean 90 %
  certainty. The thresholds are starting points.
- AI applies only to searches submitted in SafeGuard and images the user
  picks. It does not see other apps, browsers' own search boxes, pages,
  videos, messages, or the screen, and it does not classify DNS lookups.
- No image model: image classification is unavailable in this version.
- Video: `VideoSampler` exists as an interface/plan only.
- Custom mode lets the owner set thresholds up to 0.99, which effectively
  disables AI blocking for that category (with the PIN).
- DANGEROUS covers self-harm; the block screen does not yet offer help
  resources.
- UNKNOWN never blocks; `blockUnknown` exists but is not exposed.
- Nothing was run on an Android device; see §11.

## 11. Build verification

| Check | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` | 114/114 pass (93 existing + 21 new) |
| Kotlin tests (JVM harness, same test sources) | 173/173 pass (90 existing + 83 new) |
| Android layer compile check against API 36 framework + Flutter embedding | Pass |
| `cd android && ./gradlew test` | **Fails before running tests**: the Android Gradle Plugin (`com.android.application` 9.1.0) cannot be resolved — Google Maven is blocked and there is no Android SDK in this environment |
| APK build | **Not run** (same reason) |
| Robolectric `SqliteStoresTest` (incl. new AI store test) | **Not run** |
| Device tests | **Not executed** |

## 12. Manual tests (to run on a device)

| # | Steps | Expected | Result |
|---|---|---|---|
| P4-1 | Settings → الحماية الذكية | Model "sg-text-1" available; image model "غير مثبّت" | NOT EXECUTED |
| P4-2 | Search Protection box: "street fight video" | Blocked; log "ذكاء اصطناعي · المحتوى العنيف", subject `sg-text-1#…` | NOT EXECUTED |
| P4-3 | Search "online casino" | Blocked by rules (source "بحث"), AI not needed | NOT EXECUTED |
| P4-4 | Search "cake recipe", "sex education", "breast cancer" | Allowed | NOT EXECUTED |
| P4-5 | On a block screen: إبلاغ عن حظر خاطئ → إبلاغ | Counter "بلاغات حظر خاطئ" +1; nothing else stored | NOT EXECUTED |
| P4-6 | Turn AI off / STRICT → NORMAL / raise a custom threshold | PIN each time; tightening without PIN | NOT EXECUTED |
| P4-7 | "naked pictures" in NORMAL then STRICT | Allowed, then blocked | NOT EXECUTED |
| P4-8 | فحص صورة → pick a JPEG | "التصنيف غير متاح" (no model); no file created in app storage | NOT EXECUTED |
| P4-9 | Pick a GIF / a 20 MB image / a renamed text file | Rejected with the right message | NOT EXECUTED |
| P4-10 | Clear log | AI counters and reports reset | NOT EXECUTED |
| P4-11 | Upgrade from a Phase 3 install | DB v2 → v3; old events and stats intact | NOT EXECUTED |
| P4-12 | 50 searches in a row; battery stats after 1 h | No background CPU; SafeGuard not listed as a battery consumer | NOT EXECUTED |

Totals: 0 PASS, 0 FAIL, 12 NOT EXECUTED.
