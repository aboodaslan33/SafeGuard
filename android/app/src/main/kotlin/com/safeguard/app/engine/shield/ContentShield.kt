package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ClassificationStatus
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.DecisionPolicy
import com.safeguard.app.engine.ai.FinalAction
import com.safeguard.app.engine.ai.RuleSignal
import com.safeguard.app.engine.explain.DecisionExplainer
import com.safeguard.app.engine.rules.Category

/** The user's shield settings. Off until the user turns it on (it needs an accessibility permission). */
data class ShieldSettings(
    val enabled: Boolean = false,
    /** Supported-app keys the user switched off; every other supported app is inspected. */
    val disabledApps: Set<String> = emptySet(),
    /**
     * Image checks in every app, not only the supported list (system apps,
     * the launcher, the dialer and SafeGuard excepted). Text is still read
     * only in supported apps.
     */
    val allApps: Boolean = false,
    /**
     * Maximum sensitivity for images: revealing ("suggestive") images count
     * as sexual in every mode, the threshold drops to
     * [MAX_SENSITIVITY_THRESHOLD] and one frame is enough. Blocks more,
     * including more safe images by mistake.
     */
    val maxSensitivity: Boolean = false,
) {
    /** Whether the service must receive events from every app (for image checks). */
    val watchesAllApps: Boolean get() = enabled && allApps

    fun isAppEnabled(app: SupportedApp) = app.key !in disabledApps

    fun enabledApps(): List<SupportedApp> = SupportedApps.all.filter(::isAppEnabled)

    /** Package ids the accessibility service should receive events from (empty = none). */
    fun monitoredPackages(): List<String> = if (enabled) enabledApps().flatMap { it.packages }.sorted() else emptyList()

    /** True if [next] inspects less (the UI requires the PIN). */
    fun isLoosenedBy(next: ShieldSettings): Boolean =
        (enabled && !next.enabled) ||
            (enabled && (next.disabledApps - disabledApps).isNotEmpty()) ||
            (enabled && allApps && !next.allApps) ||
            (enabled && maxSensitivity && !next.maxSensitivity)

    companion object {
        /** SEXUAL threshold for images with [maxSensitivity] (policy minimum is 0.50). */
        const val MAX_SENSITIVITY_THRESHOLD = 0.60
    }
}

enum class ShieldState(val id: String) {
    /** The user hasn't turned the shield on. */
    OFF("off"),

    /** Text and image classification both running. */
    ACTIVE("active"),

    /** Running, but not every content type is covered (e.g. no image model). */
    PARTIAL("partial"),

    /** Turned on, but nothing is actually being inspected. */
    UNAVAILABLE("unavailable"),
}

/** Why the shield isn't fully active. Stable ids; the UI translates them. */
enum class ShieldIssue(val id: String) {
    PROTECTION_OFF("protection_off"),
    AI_DISABLED("ai_disabled"),
    ACCESSIBILITY_OFF("accessibility_off"),
    ACCESSIBILITY_UNAVAILABLE("accessibility_unavailable"),
    NO_APPS("no_apps"),
    TEXT_MODEL_UNAVAILABLE("text_model_unavailable"),
    IMAGE_MODEL_UNAVAILABLE("image_model_unavailable"),

    /** The image model is ready but screen capture isn't running (needs the user's consent). */
    SCREEN_CAPTURE_OFF("screen_capture_off"),
    INFERENCE_SLOW("inference_slow"),
}

data class ShieldStatus(
    val state: ShieldState,
    val issues: List<ShieldIssue>,
    val textActive: Boolean,
    val imageActive: Boolean,
)

/**
 * The shield's real state. It never reports ACTIVE unless both text and
 * image classification can run right now, and never anything but OFF or
 * UNAVAILABLE when nothing is inspected.
 */
object ShieldStatusResolver {
    fun resolve(
        settings: ShieldSettings,
        /** Protection on and not paused. */
        protectionActive: Boolean,
        aiEnabled: Boolean,
        accessibilityEnabled: Boolean,
        accessibilityAvailable: Boolean,
        textModelAvailable: Boolean,
        imageModelAvailable: Boolean,
        /** MediaProjection capture is running (the user consented this session). */
        screenCaptureActive: Boolean = false,
        textSlow: Boolean = false,
        imageSlow: Boolean = false,
    ): ShieldStatus {
        if (!settings.enabled) return ShieldStatus(ShieldState.OFF, emptyList(), false, false)
        val blocking = buildList {
            if (!protectionActive) add(ShieldIssue.PROTECTION_OFF)
            if (!aiEnabled) add(ShieldIssue.AI_DISABLED)
            if (!accessibilityAvailable) add(ShieldIssue.ACCESSIBILITY_UNAVAILABLE)
            else if (!accessibilityEnabled) add(ShieldIssue.ACCESSIBILITY_OFF)
            if (settings.enabledApps().isEmpty()) add(ShieldIssue.NO_APPS)
        }
        val partial = buildList {
            if (!textModelAvailable) add(ShieldIssue.TEXT_MODEL_UNAVAILABLE)
            if (!imageModelAvailable) add(ShieldIssue.IMAGE_MODEL_UNAVAILABLE)
            else if (!screenCaptureActive) add(ShieldIssue.SCREEN_CAPTURE_OFF)
            if ((textModelAvailable && textSlow) || (imageModelAvailable && imageSlow)) add(ShieldIssue.INFERENCE_SLOW)
        }
        val text = blocking.isEmpty() && textModelAvailable && !textSlow
        val image = blocking.isEmpty() && imageModelAvailable && screenCaptureActive && !imageSlow
        val state = when {
            !text && !image -> ShieldState.UNAVAILABLE
            partial.isEmpty() -> ShieldState.ACTIVE
            else -> ShieldState.PARTIAL
        }
        return ShieldStatus(state, blocking + partial, text, image)
    }
}

/**
 * Inference that takes too long is treated as a failure: after
 * [maxConsecutive] slow runs the content kind is paused for [pauseMs]
 * (then retried), so a slow device can't be kept busy in a loop. A running
 * inference can't be interrupted; the pause stops new ones.
 */
class InferenceWatchdog(
    private val limitMs: Long,
    private val maxConsecutive: Int = 3,
    private val pauseMs: Long = 60_000,
) {
    private var consecutive = 0
    private var pausedUntil = Long.MIN_VALUE

    @Synchronized
    fun canRun(now: Long) = now >= pausedUntil

    @Synchronized
    fun isSlow(now: Long) = now < pausedUntil

    /** Records one run; returns true if it counts as a timeout. */
    @Synchronized
    fun record(now: Long, elapsedMs: Long): Boolean {
        if (elapsedMs <= limitMs) {
            consecutive = 0
            return false
        }
        consecutive++
        if (consecutive >= maxConsecutive) {
            pausedUntil = now + pauseMs
            consecutive = 0
        }
        return true
    }
}

/**
 * What SafeGuard does with blocked content. It never leaves the app: the
 * content is covered, then skipped.
 */
enum class BlockAction(val id: String) {
    /** Cover the screen for a moment and swipe to the next item (reels, shorts, feeds). */
    SKIP("skip"),

    /**
     * Skipping didn't help (a single post, a profile, search results): keep
     * the content covered until the user chooses "Next" or "Back".
     */
    COVER("cover"),
}

/**
 * Chooses the action for a block. The first [skipsBeforeCover] blocks in
 * the same app within [windowMs] of each other skip; if blocked content
 * keeps coming back, it stays covered instead. A quiet period, another app
 * or the user's choice on the cover starts again from skip.
 */
class BlockEscalation(
    private val windowMs: Long = 8_000,
    private val skipsBeforeCover: Int = 2,
) {
    private var lastPackage: String? = null
    private var lastAt = Long.MIN_VALUE / 2
    private var count = 0

    @Synchronized
    fun next(packageName: String, now: Long): BlockAction {
        count = if (packageName == lastPackage && now - lastAt <= windowMs) count + 1 else 1
        lastPackage = packageName
        lastAt = now
        return if (count <= skipsBeforeCover) BlockAction.SKIP else BlockAction.COVER
    }

    @Synchronized
    fun reset() {
        lastPackage = null
        count = 0
    }
}

/**
 * Recognises the search box of a supported app from what accessibility
 * reports about the focused, editable field. Only such a field is ever
 * read; message boxes and other inputs are not.
 */
object SearchFieldDetector {
    private val WORDS = listOf("search", "بحث", "ابحث")

    fun isSearchField(viewId: String?, hint: CharSequence?, description: CharSequence?, className: CharSequence?): Boolean {
        val id = viewId?.substringAfter(":id/", viewId)?.lowercase()
        if (id != null && "search" in id) return true
        if (className?.toString()?.endsWith("SearchView\$SearchAutoComplete") == true) return true
        return listOfNotNull(hint, description).any { t -> WORDS.any { t.toString().contains(it, ignoreCase = true) } }
    }

    /** The query worth checking, or null (too short, or just the hint). */
    fun query(text: CharSequence?, showingHint: Boolean): String? {
        if (showingHint) return null
        val q = text?.toString()?.trim()?.take(MAX_QUERY) ?: return null
        return q.takeIf { it.count(Char::isLetterOrDigit) >= 2 }
    }

    const val MAX_QUERY = 200
}

/** What happened with one sample. */
sealed interface ShieldOutcome {
    /** Not inspected (shield off, app not enabled, throttled, same screen…). */
    data object Skipped : ShieldOutcome

    /** Classified; the policy engine allowed it (or said UNKNOWN). */
    data class Allowed(val decision: ShieldDecision) : ShieldOutcome

    /** Classified as risky once; waiting for a confirming sample. */
    data class Pending(val decision: ShieldDecision) : ShieldOutcome

    /** Blocked: the caller hides the content. */
    data class Blocked(val event: ShieldEvent) : ShieldOutcome
}

/**
 * Everything the log keeps about a shield block: no text, no image, no
 * hash of either. [packageName] is the app (as for protected apps).
 */
data class ShieldEvent(
    val timestamp: Long,
    val packageName: String,
    val kind: ContentKind,
    val label: AiLabel,
    val category: Category,
    /** Confidence rounded down to 10 % steps. */
    val confidenceBucket: Int,
    val modelVersion: String,
) {
    /** Stored as the event's rule type: `ai_shield:<kind>:<label>:<model>`. */
    val ruleType: String get() = "$RULE_TYPE_PREFIX${kind.name.lowercase()}:${label.id}:$modelVersion"

    companion object {
        const val RULE_TYPE_PREFIX = DecisionExplainer.SHIELD_RULE_TYPE_PREFIX
    }
}

/**
 * AI Content Shield orchestration, independent of Android:
 *
 * sample (text snapshot or frame) → gate (throttle, debounce, same-screen
 * skip) → classify on device (with a watchdog) → temporal confirmation →
 * existing policy engine → BLOCK / ALLOW / UNKNOWN.
 *
 * Only packages in [SupportedApps] that the user left enabled are ever
 * considered, and nothing runs while protection or the shield is off.
 * Inputs are never stored; only [ShieldEvent] metadata is reported for
 * blocks.
 */
class ContentShieldEngine(
    private val classifyText: (String) -> ClassificationResult,
    private val image: ShieldImageClassifier,
    private val policy: () -> DecisionPolicy,
    private val settings: () -> ShieldSettings,
    /** Protection on, not paused. */
    private val protectionActive: () -> Boolean,
    /** Apps never inspected even with "all apps" (launcher, dialer, system UI, SafeGuard…). */
    private val isExempt: (String) -> Boolean = { false },
    private val clock: () -> Long = System::currentTimeMillis,
    private val textWatchdog: InferenceWatchdog = InferenceWatchdog(limitMs = 250),
    private val imageWatchdog: InferenceWatchdog = InferenceWatchdog(limitMs = 1_500),
    /** A second block of the same app within this time is the same content (debounce). */
    private val blockCooldownMs: Long = 1_200,
    /** Content-free counters for the diagnostics screen. */
    val diagnostics: ShieldDiagnostics = ShieldDiagnostics(clock),
) {
    private val textGate = FrameGate(minIntervalMs = 1_000, settleMs = 400, maxWaitMs = 2_500, sameScreenBits = 0)
    private val imageGate = FrameGate()
    private val imageGateFast = FrameGate(minIntervalMs = 450, settleMs = 200, maxWaitMs = 1_000)
    private val textConfirm = TemporalConfirmer()
    private val imageConfirm = TemporalConfirmer()
    private val imageConfirmMax = TemporalConfirmer(confirmations = 1)
    @Volatile private var foreground: String? = null
    @Volatile private var lastTextHash: Long? = null
    @Volatile private var textPending = false
    private val lastBlockAt = HashMap<String, Long>()

    val textSlow: Boolean get() = textWatchdog.isSlow(clock())
    val imageSlow: Boolean get() = imageWatchdog.isSlow(clock())

    /**
     * Whether [kind] content of [pkg] may be inspected right now. Text: only
     * supported apps the user left on. Images: the same, plus every other
     * non-exempt app when "all apps" is on.
     */
    fun isActiveFor(pkg: String?, kind: ContentKind = ContentKind.TEXT): Boolean {
        if (pkg == null) return false
        val s = settings()
        if (!s.enabled || !protectionActive() || !policy().ai.enabled) return false
        val app = SupportedApps.forPackage(pkg)
        return if (app != null) s.isAppEnabled(app) else kind == ContentKind.IMAGE && s.allApps && !isExempt(pkg)
    }

    /** The foreground app changed: evidence from the previous app is dropped. */
    fun onForeground(pkg: String?) {
        if (pkg == foreground) return
        foreground = pkg
        lastTextHash = null
        textPending = false
        textGate.reset(); imageGate.reset(); imageGateFast.reset()
        textConfirm.reset(); imageConfirm.reset(); imageConfirmMax.reset()
    }

    /** Scrolling or other content changes (debounces sampling). */
    fun onContentChanged() {
        val now = clock()
        textGate.onContentChanged(now)
        onImageContentChanged(now)
    }

    /** Whether a text snapshot should be taken now (call before walking the node tree). */
    fun wantsText(pkg: String?): Boolean =
        isActiveFor(pkg, ContentKind.TEXT) && textWatchdog.canRun(clock()) && textGate.shouldSample(clock(), null, true)

    fun onText(pkg: String, text: String): ShieldOutcome {
        if (!isActiveFor(pkg, ContentKind.TEXT) || text.isBlank()) return ShieldOutcome.Skipped
        // Same text as last time and nothing to confirm: nothing new to learn.
        val hash = FrameHash.text(text)
        if (hash == lastTextHash && !textPending) return ShieldOutcome.Skipped
        lastTextHash = hash
        val start = clock()
        val result = try {
            classifyText(text)
        } catch (e: OutOfMemoryError) {
            ClassificationResult(ClassificationStatus.UNAVAILABLE)
        } catch (e: Exception) {
            ClassificationResult(ClassificationStatus.UNAVAILABLE)
        }
        textWatchdog.record(clock(), clock() - start)
        val classified = AiClassification.fromText(result)
        diagnostics.onClassified(classified)
        return decide(pkg, classified, textConfirm, textGate).also {
            textPending = it is ShieldOutcome.Pending
        }
    }

    /** [frame] is read in place and must be released by the caller afterwards. */
    fun onFrame(pkg: String, frame: RgbaFrame): ShieldOutcome {
        if (!isActiveFor(pkg, ContentKind.IMAGE)) {
            diagnostics.framesInactive.incrementAndGet()
            return ShieldOutcome.Skipped
        }
        if (!image.isUsable) {
            diagnostics.framesNoModel.incrementAndGet()
            return ShieldOutcome.Skipped
        }
        val max = settings().maxSensitivity
        val gate = if (max) imageGateFast else imageGate
        val now = clock()
        if (!imageWatchdog.canRun(now)) return ShieldOutcome.Skipped
        if (!gate.shouldSample(now, FrameHash.dHash(frame), true)) return ShieldOutcome.Skipped
        val c = image.classify(frame)
        imageWatchdog.record(clock(), clock() - now)
        diagnostics.onClassified(c)
        return decide(pkg, c, if (max) imageConfirmMax else imageConfirm, gate, maxSensitivity = max)
    }

    /** Scrolling or other content changes (debounces sampling). Kept for both image gates. */
    private fun onImageContentChanged(now: Long) {
        imageGate.onContentChanged(now)
        imageGateFast.onContentChanged(now)
    }

    /** Frees the image model (protection or shield stopped). */
    fun release() {
        image.close()
        onForeground(null)
    }

    private fun decide(
        pkg: String,
        c: AiClassification,
        confirm: TemporalConfirmer,
        gate: FrameGate,
        maxSensitivity: Boolean = false,
    ): ShieldOutcome {
        val base = policy()
        // Maximum sensitivity only lowers the SEXUAL threshold for images; the
        // policy engine, category toggles and protection state still apply.
        val p = if (maxSensitivity) ShieldScores.maxSensitivityPolicy(base) else base
        val now = clock()
        val suggestive = maxSensitivity || ShieldScores.blockSuggestive(base.ai.mode)
        val evidence = confirm.add(now, ShieldScores.toResult(c, suggestive))
        val d = ShieldPolicy.decide(RuleSignal.None, evidence, c, p)
        val pending = evidence.status == ClassificationStatus.UNCERTAIN && c.status == ClassificationStatus.OK
        gate.onResult(pending)
        if (d.decision.action != FinalAction.BLOCK) {
            return if (pending) ShieldOutcome.Pending(d) else ShieldOutcome.Allowed(d)
        }
        synchronized(lastBlockAt) {
            val last = lastBlockAt[pkg]
            // Already handled: the user was just sent away from this content.
            if (last != null && now - last < blockCooldownMs) return ShieldOutcome.Skipped
            lastBlockAt[pkg] = now
        }
        confirm.reset()
        val label = if (c.label.isRisk && c.label.category == d.decision.category) c.label else AiLabel.of(d.decision.category)
        return ShieldOutcome.Blocked(
            ShieldEvent(
                timestamp = now,
                packageName = pkg,
                kind = c.kind,
                label = label,
                category = d.decision.category,
                confidenceBucket = confidenceBucket(d.decision.confidence),
                modelVersion = c.modelVersion ?: "unknown",
            ),
        )
    }
}
