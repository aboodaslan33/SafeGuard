package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ClassificationStatus
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.DecisionPolicy
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.ai.ProtectionDecision
import com.safeguard.app.engine.ai.ProtectionDecisionEngine
import com.safeguard.app.engine.ai.RuleSignal
import com.safeguard.app.engine.ai.ThresholdProfiles
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category

/**
 * Turns an [AiClassification] into the per-category scores the existing
 * [ProtectionDecisionEngine] understands. The AI never decides on its own:
 * it only supplies evidence; thresholds, category toggles, modes and rules
 * stay with the policy engine.
 */
object ShieldScores {

    /** SUGGESTIVE counts toward the SEXUAL category only in STRICT mode. */
    fun blockSuggestive(mode: DetectionMode): Boolean = mode == DetectionMode.STRICT

    /**
     * The policy for images with maximum sensitivity: the same policy with
     * the SEXUAL threshold lowered to [ShieldSettings.MAX_SENSITIVITY_THRESHOLD]
     * (never raised). Other categories keep their thresholds.
     */
    fun maxSensitivityPolicy(p: DecisionPolicy): DecisionPolicy {
        val thresholds = Category.filterable.associateWith { c ->
            if (c == Category.SEXUAL) minOf(p.ai.threshold(c), ShieldSettings.MAX_SENSITIVITY_THRESHOLD) else p.ai.threshold(c)
        }
        return p.copy(ai = AiSettings(enabled = p.ai.enabled, mode = DetectionMode.CUSTOM, customThresholds = thresholds))
    }

    fun toResult(c: AiClassification, blockSuggestive: Boolean): ClassificationResult {
        val status = c.status
        if (status != ClassificationStatus.OK && status != ClassificationStatus.UNCERTAIN) {
            return ClassificationResult(status, modelId = c.modelVersion)
        }
        val scores = LinkedHashMap<Category, Double>()
        when (c.kind) {
            // Independent sigmoids: a category's score is its own output.
            ContentKind.TEXT -> c.scores.forEach { (l, s) ->
                if (l.isRisk && (l != AiLabel.SUGGESTIVE || blockSuggestive)) {
                    scores[l.category] = maxOf(scores[l.category] ?: 0.0, s)
                }
            }
            // Mutually exclusive softmax classes: a category's probability is
            // the sum of its labels' probabilities (e.g. SEXUAL + NUDITY).
            ContentKind.IMAGE -> c.scores.forEach { (l, s) ->
                if (l.isRisk && (l != AiLabel.SUGGESTIVE || blockSuggestive)) {
                    scores[l.category] = ((scores[l.category] ?: 0.0) + s).coerceAtMost(1.0)
                }
            }
        }
        scores[Category.SAFE] = if (c.kind == ContentKind.IMAGE) c.score(AiLabel.SAFE) else ClassificationResult.safeScore(scores)
        return ClassificationResult(status, scores, c.modelVersion)
    }
}

/**
 * Temporal confirmation: one uncertain frame never blocks.
 *
 * - Clearly safe results (no risk score ≥ [ThresholdProfiles.UNCERTAIN_FLOOR]) pass
 *   straight through and end any streak of risky samples.
 * - A risk score ≥ [instant] passes straight through, so obvious content is
 *   blocked on the first sample.
 * - Otherwise the evidence handed to the policy engine is, per category,
 *   the **minimum** of the last [confirmations] risky samples within [windowMs]:
 *   the category must stay high. Each value is a real model output from one
 *   of those samples. Until enough samples exist the result is UNCERTAIN
 *   (the policy engine reports UNKNOWN — not blocked, not "safe").
 *
 * Example (STRICT threshold 0.70, SEXUAL): 0.55 → pending; 0.72 → evidence
 * 0.55 (not blocked); 0.94 → evidence 0.72 → BLOCK. In NORMAL (0.90) the
 * same sequence needs one more sample ≥ 0.90, or one ≥ [instant].
 */
class TemporalConfirmer(
    private val windowMs: Long = 5_000,
    private val confirmations: Int = 2,
    private val instant: Double = 0.97,
) {
    init {
        require(confirmations in 1..10)
        require(windowMs > 0)
        require(instant in 0.5..1.0)
    }

    private val history = ArrayDeque<Pair<Long, ClassificationResult>>()

    @Synchronized
    fun reset() = history.clear()

    @Synchronized
    fun add(now: Long, r: ClassificationResult): ClassificationResult {
        if (r.status != ClassificationStatus.OK) {
            // Not usable as evidence either way; a streak must restart.
            history.clear()
            return r
        }
        val risk = r.scores.filterKeys { it.isFilterable }
        val top = risk.values.maxOrNull() ?: 0.0
        if (top < ThresholdProfiles.UNCERTAIN_FLOOR) {
            // Clearly safe: any streak of risky samples is broken.
            history.clear()
            return r
        }
        if (top >= instant) return r

        // Only risky samples count toward confirmation.
        while (history.isNotEmpty() && now - history.first().first > windowMs) history.removeFirst()
        history.addLast(now to r)
        while (history.size > confirmations) history.removeFirst()
        if (history.size < confirmations) return r.copy(status = ClassificationStatus.UNCERTAIN)

        val confirmed = LinkedHashMap<Category, Double>()
        for (c in risk.keys) confirmed[c] = history.minOf { it.second.score(c) }
        confirmed[Category.SAFE] = r.score(Category.SAFE)
        return r.copy(scores = confirmed)
    }
}

/** What the shield decided for one sample, with everything the log may keep. */
data class ShieldDecision(
    val decision: ProtectionDecision,
    val classification: AiClassification,
) {
    val blocks: Boolean get() = decision.blocks
}

object ShieldPolicy {
    /**
     * Existing policy engine, unchanged: protection toggle, user rules,
     * category toggles, mode thresholds, UNKNOWN handling.
     */
    fun decide(rule: RuleSignal, evidence: ClassificationResult, classification: AiClassification, policy: DecisionPolicy): ShieldDecision =
        ShieldDecision(ProtectionDecisionEngine.decide(rule, evidence, policy, EventSource.AI), classification)
}
