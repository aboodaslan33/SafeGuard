package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ClassificationStatus
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.ThresholdProfiles
import com.safeguard.app.engine.rules.Category

/**
 * What an AI model can say about content. Finer than the policy
 * [Category] toggles: SUGGESTIVE, SEXUAL and NUDITY are separate labels so
 * a model can tell them apart, but they are governed by the one SEXUAL
 * category toggle (SUGGESTIVE only when the mode says so, see
 * [ShieldScores]). [id] is stored in logs; never rename.
 */
enum class AiLabel(val id: String, val category: Category) {
    SAFE("safe", Category.SAFE),
    SUGGESTIVE("suggestive", Category.SEXUAL),
    SEXUAL("sexual", Category.SEXUAL),
    NUDITY("nudity", Category.SEXUAL),
    VIOLENCE("violence", Category.VIOLENCE),
    GORE("gore", Category.GORE),
    GAMBLING("gambling", Category.GAMBLING),
    DRUGS("drugs", Category.DRUGS),
    DANGEROUS("dangerous", Category.DANGEROUS),
    UNKNOWN("unknown", Category.UNKNOWN);

    val isRisk: Boolean get() = this != SAFE && this != UNKNOWN

    companion object {
        fun fromId(id: String?): AiLabel? = entries.firstOrNull { it.id == id }

        /** The label a text-model category maps to (text models have no SUGGESTIVE/NUDITY). */
        fun of(category: Category): AiLabel = when (category) {
            Category.SEXUAL -> SEXUAL
            Category.VIOLENCE -> VIOLENCE
            Category.GORE -> GORE
            Category.GAMBLING -> GAMBLING
            Category.DRUGS -> DRUGS
            Category.DANGEROUS -> DANGEROUS
            Category.SAFE -> SAFE
            Category.UNKNOWN, Category.CUSTOM -> UNKNOWN
        }
    }
}

/**
 * One AI classification as the rest of SafeGuard sees it: the top label,
 * its confidence and the model that produced it.
 *
 * [confidence] is always a number the model produced for [label], never a
 * rule score or a made-up value, with one documented exception: a text
 * model has independent per-category sigmoids and no SAFE output, so its
 * SAFE confidence is derived from them ([ClassificationResult.safeScore])
 * and [derived] is true. UNKNOWN carries the highest score seen (or 0 when
 * no model ran), so "UNKNOWN 0.31" means the model was not sure.
 */
data class AiClassification(
    val label: AiLabel,
    val confidence: Double,
    /** e.g. "sg-text-1"; null when no model ran. */
    val modelVersion: String?,
    val kind: ContentKind,
    /** Every label the model scored (actual outputs). Never contains the input. */
    val scores: Map<AiLabel, Double> = emptyMap(),
    val derived: Boolean = false,
    val status: ClassificationStatus = ClassificationStatus.OK,
) {
    fun score(l: AiLabel) = scores[l] ?: 0.0

    companion object {
        /** A top risk score below this is SAFE; same floor as the decision engine. */
        const val UNCERTAIN_FLOOR = ThresholdProfiles.UNCERTAIN_FLOOR

        fun unavailable(kind: ContentKind, status: ClassificationStatus, modelVersion: String? = null) =
            AiClassification(AiLabel.UNKNOWN, 0.0, modelVersion, kind, status = status)

        /** From the text pipeline's category scores (multi-label sigmoids). */
        fun fromText(r: ClassificationResult): AiClassification {
            if (r.status != ClassificationStatus.OK && r.status != ClassificationStatus.UNCERTAIN) {
                return unavailable(ContentKind.TEXT, r.status, r.modelId)
            }
            val scores = LinkedHashMap<AiLabel, Double>()
            r.scores.forEach { (c, s) -> scores[AiLabel.of(c)] = s }
            val top = scores.filterKeys { it.isRisk }.maxByOrNull { it.value }
            return when {
                r.status == ClassificationStatus.UNCERTAIN ->
                    AiClassification(AiLabel.UNKNOWN, top?.value ?: 0.0, r.modelId, ContentKind.TEXT, scores, status = r.status)
                top != null && top.value >= UNCERTAIN_FLOOR ->
                    AiClassification(top.key, top.value, r.modelId, ContentKind.TEXT, scores)
                else ->
                    AiClassification(AiLabel.SAFE, r.score(Category.SAFE), r.modelId, ContentKind.TEXT, scores, derived = true)
            }
        }

        /**
         * From a single-label image model (softmax over [AiLabel]s): the
         * label is the arg-max and the confidence its probability.
         */
        fun fromProbabilities(probs: Map<AiLabel, Double>, modelVersion: String, minConfidence: Double): AiClassification {
            val top = probs.maxByOrNull { it.value }
                ?: return unavailable(ContentKind.IMAGE, ClassificationStatus.UNAVAILABLE, modelVersion)
            return if (top.value < minConfidence) {
                AiClassification(AiLabel.UNKNOWN, top.value, modelVersion, ContentKind.IMAGE, probs, status = ClassificationStatus.UNCERTAIN)
            } else {
                AiClassification(top.key, top.value, modelVersion, ContentKind.IMAGE, probs)
            }
        }
    }
}

/** Confidence rounded down to 10 % steps (0–100): all the log ever stores. */
fun confidenceBucket(confidence: Double): Int =
    if (confidence.isNaN()) 0 else (confidence.coerceIn(0.0, 1.0) * 10).toInt() * 10
