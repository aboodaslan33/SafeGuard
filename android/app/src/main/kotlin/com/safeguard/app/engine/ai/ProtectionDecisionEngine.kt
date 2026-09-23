package com.safeguard.app.engine.ai

import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category

/** How eagerly AI results block. [id] is stored; never rename. */
enum class DetectionMode(val id: String) {
    /** Block only high-confidence detections. */
    NORMAL("normal"),

    /** Lower thresholds: blocks more, including more false positives. */
    STRICT("strict"),

    /** The user sets each threshold. */
    CUSTOM("custom");

    companion object {
        fun fromId(id: String?) = entries.firstOrNull { it.id == id } ?: NORMAL
    }
}

/**
 * Per-category thresholds. Starting points only — not tuned optima; the
 * model's scores are not calibrated probabilities (see docs/PHASE_4_AI.md).
 */
object ThresholdProfiles {
    val NORMAL: Map<Category, Double> = mapOf(
        Category.SEXUAL to 0.90,
        Category.VIOLENCE to 0.90,
        Category.GORE to 0.85,
        Category.GAMBLING to 0.90,
        Category.DRUGS to 0.90,
        Category.DANGEROUS to 0.90,
    )

    val STRICT: Map<Category, Double> = mapOf(
        Category.SEXUAL to 0.70,
        Category.VIOLENCE to 0.75,
        Category.GORE to 0.65,
        Category.GAMBLING to 0.70,
        Category.DRUGS to 0.70,
        Category.DANGEROUS to 0.75,
    )

    const val MIN_CUSTOM = 0.50
    const val MAX_CUSTOM = 0.99

    /** Scores in [UNCERTAIN_FLOOR, threshold) are UNKNOWN, not SAFE. */
    const val UNCERTAIN_FLOOR = 0.50

    /** Clamps to the allowed range and rounds to two decimals; NaN → the strictest-safe maximum. */
    fun clampCustom(v: Double): Double =
        if (v.isNaN()) MAX_CUSTOM else Math.round(v.coerceIn(MIN_CUSTOM, MAX_CUSTOM) * 100) / 100.0
}

data class AiSettings(
    val enabled: Boolean = true,
    val mode: DetectionMode = DetectionMode.NORMAL,
    /** Used in CUSTOM mode; missing categories fall back to NORMAL. */
    val customThresholds: Map<Category, Double> = emptyMap(),
) {
    fun threshold(c: Category): Double = when (mode) {
        DetectionMode.NORMAL -> ThresholdProfiles.NORMAL[c]
        DetectionMode.STRICT -> ThresholdProfiles.STRICT[c]
        DetectionMode.CUSTOM -> customThresholds[c]?.let(ThresholdProfiles::clampCustom) ?: ThresholdProfiles.NORMAL[c]
    } ?: 1.0

    val thresholds: Map<Category, Double> get() = Category.filterable.associateWith(::threshold)

    /** True if [next] blocks less than this in any way (the UI requires the PIN). */
    fun isLoosenedBy(next: AiSettings): Boolean =
        (enabled && !next.enabled) || Category.filterable.any { next.threshold(it) > threshold(it) + 1e-9 }

    companion object {
        val OFF = AiSettings(enabled = false)
    }
}

/** How to resolve rule-vs-AI disagreements. Explicit and testable, never random. */
data class ConflictPolicy(
    /** A built-in SAFE/allow rule keeps content allowed even if AI flags it. */
    val safeRuleWinsOverAi: Boolean = true,
    /** Block UNKNOWN outcomes. Off in every shipped mode. */
    val blockUnknown: Boolean = false,
)

/** What the deterministic rule layer said about this content. */
sealed interface RuleSignal {
    data object None : RuleSignal

    /** [explicit] = user allowlist (always wins); otherwise a built-in SAFE rule. */
    data class Allow(val explicit: Boolean) : RuleSignal

    /** [explicit] = user blocklist (applies whatever the category toggles). */
    data class Block(val category: Category, val confidence: Double, val ruleId: String?, val explicit: Boolean = false) : RuleSignal
}

data class DecisionPolicy(
    val protectionEnabled: Boolean,
    /** Shared category toggles (same as DNS and search). */
    val blockedCategories: Set<Category>,
    val ai: AiSettings,
    val conflict: ConflictPolicy = ConflictPolicy(),
)

enum class FinalAction { ALLOW, BLOCK, UNKNOWN }

enum class DecidedBy { NONE, RULE, AI }

data class ProtectionDecision(
    val action: FinalAction,
    val category: Category,
    val confidence: Double,
    val decidedBy: DecidedBy,
    /** Stable reason id (see [ProtectionDecisionEngine]). */
    val reason: String,
    /** Every enabled category at or above its threshold (multi-label). */
    val exceeded: List<Category> = emptyList(),
    /** Every category at or above its threshold, enabled or not (statistics). */
    val detected: List<Category> = emptyList(),
    val modelId: String? = null,
    val ruleId: String? = null,
    val source: EventSource,
) {
    val blocks: Boolean get() = action == FinalAction.BLOCK
}

/**
 * Combines the rule layer, the AI result and the user's settings into one
 * decision. First match wins:
 *
 * 1. protection off → ALLOW `protection_off`
 * 2. user allowlist → ALLOW `user_allowlist`
 * 3. blocking rule (enabled category, or user blocklist) → BLOCK `rule`
 * 4. AI off or not consulted → ALLOW `ai_off`
 * 5. AI unavailable / input rejected → UNKNOWN `ai_unavailable` / `input_rejected`
 * 6. model uncertain about the input → UNKNOWN `ai_uncertain`
 * 7. enabled categories ≥ threshold → BLOCK `ai_threshold` (highest score),
 *    unless a built-in SAFE rule matched and the conflict policy keeps it
 *    → ALLOW `safe_rule_over_ai`
 * 8. highest enabled score in [UNCERTAIN_FLOOR, threshold) → UNKNOWN `below_threshold`
 * 9. otherwise → ALLOW `ai_safe`
 *
 * UNKNOWN is reported as such; callers treat it as not blocked unless
 * [ConflictPolicy.blockUnknown] (never set by the UI) turns it into BLOCK.
 */
object ProtectionDecisionEngine {

    fun decide(rule: RuleSignal, ai: ClassificationResult?, policy: DecisionPolicy, source: EventSource): ProtectionDecision {
        fun d(
            action: FinalAction,
            reason: String,
            category: Category = Category.UNKNOWN,
            confidence: Double = 0.0,
            by: DecidedBy = DecidedBy.NONE,
            exceeded: List<Category> = emptyList(),
            detected: List<Category> = emptyList(),
        ) = ProtectionDecision(
            action = if (action == FinalAction.UNKNOWN && policy.conflict.blockUnknown) FinalAction.BLOCK else action,
            category = category,
            confidence = confidence.coerceIn(0.0, 1.0),
            decidedBy = by,
            reason = reason,
            exceeded = exceeded,
            detected = detected,
            modelId = ai?.modelId,
            ruleId = (rule as? RuleSignal.Block)?.ruleId,
            source = source,
        )

        if (!policy.protectionEnabled) return d(FinalAction.ALLOW, "protection_off")
        if (rule is RuleSignal.Allow && rule.explicit) return d(FinalAction.ALLOW, "user_allowlist", Category.SAFE, 1.0, DecidedBy.RULE)
        if (rule is RuleSignal.Block && (rule.explicit || rule.category in policy.blockedCategories)) {
            return d(FinalAction.BLOCK, "rule", rule.category, rule.confidence, DecidedBy.RULE)
        }
        if (!policy.ai.enabled || ai == null) return d(FinalAction.ALLOW, "ai_off")
        when (ai.status) {
            ClassificationStatus.UNAVAILABLE -> return d(FinalAction.UNKNOWN, "ai_unavailable")
            ClassificationStatus.REJECTED -> return d(FinalAction.UNKNOWN, "input_rejected")
            ClassificationStatus.UNCERTAIN -> return d(FinalAction.UNKNOWN, "ai_uncertain", by = DecidedBy.AI)
            ClassificationStatus.OK -> Unit
        }

        val risk = ai.scores.filterKeys { it.isFilterable }
        val detected = risk.filter { (c, s) -> s >= policy.ai.threshold(c) }
            .entries.sortedByDescending { it.value }.map { it.key }
        val exceeded = detected.filter { it in policy.blockedCategories }
        if (exceeded.isNotEmpty()) {
            val top = exceeded.first()
            if (rule is RuleSignal.Allow && policy.conflict.safeRuleWinsOverAi) {
                return d(FinalAction.ALLOW, "safe_rule_over_ai", Category.SAFE, ai.score(top), DecidedBy.RULE, exceeded, detected)
            }
            return d(FinalAction.BLOCK, "ai_threshold", top, ai.score(top), DecidedBy.AI, exceeded, detected)
        }

        val topEnabled = risk.filterKeys { it in policy.blockedCategories }.maxByOrNull { it.value }
        if (topEnabled != null && topEnabled.value >= ThresholdProfiles.UNCERTAIN_FLOOR) {
            return d(FinalAction.UNKNOWN, "below_threshold", topEnabled.key, topEnabled.value, DecidedBy.AI, detected = detected)
        }
        return d(FinalAction.ALLOW, "ai_safe", Category.SAFE, ai.score(Category.SAFE), DecidedBy.AI, detected = detected)
    }
}
