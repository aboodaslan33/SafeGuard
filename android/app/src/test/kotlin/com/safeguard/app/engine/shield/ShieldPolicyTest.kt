package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ClassificationStatus
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.DecisionPolicy
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.ai.FinalAction
import com.safeguard.app.engine.ai.RuleSignal
import com.safeguard.app.engine.rules.Category
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AI result → existing policy engine. The classifications here are written
 * by hand (they stand in for model outputs); what's tested is how the
 * policy treats them, for every label and confidence band.
 */
class ShieldPolicyTest {

    private fun policy(mode: DetectionMode = DetectionMode.NORMAL, categories: Set<Category> = Category.filterable.toSet(), on: Boolean = true, ai: Boolean = true) =
        DecisionPolicy(on, categories, AiSettings(enabled = ai, mode = mode))

    /** A single-label image result: [label] gets [p], SAFE the rest. */
    private fun image(label: AiLabel, p: Double): AiClassification {
        val probs = if (label == AiLabel.SAFE) mapOf(AiLabel.SAFE to p, AiLabel.SEXUAL to 1 - p) else mapOf(label to p, AiLabel.SAFE to 1 - p)
        return AiClassification.fromProbabilities(probs, "test@1", minConfidence = 0.4)
    }

    private fun decide(c: AiClassification, p: DecisionPolicy = policy()): FinalAction {
        val evidence = ShieldScores.toResult(c, ShieldScores.blockSuggestive(p.ai.mode))
        return ShieldPolicy.decide(RuleSignal.None, evidence, c, p).decision.action
    }

    @Test fun everyRiskLabelBlocksAtHighConfidenceWhenItsCategoryIsOn() {
        for (l in listOf(AiLabel.SEXUAL, AiLabel.NUDITY, AiLabel.VIOLENCE, AiLabel.GORE, AiLabel.GAMBLING, AiLabel.DRUGS, AiLabel.DANGEROUS)) {
            assertEquals(l.name, FinalAction.BLOCK, decide(image(l, 0.96)))
            // Category switched off → the policy allows, whatever the AI says.
            assertEquals(l.name, FinalAction.ALLOW, decide(image(l, 0.96), policy(categories = Category.filterable.toSet() - l.category)))
        }
    }

    @Test fun safeHighConfidenceIsAllowed() {
        assertEquals(FinalAction.ALLOW, decide(image(AiLabel.SAFE, 0.98)))
    }

    @Test fun suggestiveCountsOnlyInStrictMode() {
        // Spec example: SUGGESTIVE 0.61 with a 0.80-ish threshold → ALLOW.
        assertEquals(FinalAction.ALLOW, decide(image(AiLabel.SUGGESTIVE, 0.61)))
        assertEquals(FinalAction.ALLOW, decide(image(AiLabel.SUGGESTIVE, 0.99)))
        assertEquals(FinalAction.BLOCK, decide(image(AiLabel.SUGGESTIVE, 0.75), policy(DetectionMode.STRICT)))
        assertEquals(FinalAction.UNKNOWN, decide(image(AiLabel.SUGGESTIVE, 0.61), policy(DetectionMode.STRICT)))
    }

    @Test fun borderlineIsUnknownNotBlockedAndLowIsAllowed() {
        assertEquals(FinalAction.UNKNOWN, decide(image(AiLabel.SEXUAL, 0.70)))
        assertEquals(FinalAction.ALLOW, decide(image(AiLabel.SEXUAL, 0.20)))
        assertEquals(FinalAction.BLOCK, decide(image(AiLabel.SEXUAL, 0.90)))
    }

    @Test fun unknownIsNeverSilentlyTurnedIntoBlock() {
        val low = AiClassification.fromProbabilities(mapOf(AiLabel.SEXUAL to 0.31, AiLabel.SAFE to 0.30, AiLabel.VIOLENCE to 0.39), "test@1", 0.5)
        assertEquals(AiLabel.UNKNOWN, low.label)
        assertEquals(0.39, low.confidence, 1e-9)
        assertEquals(FinalAction.UNKNOWN, decide(low))
        val unavailable = AiClassification.unavailable(ContentKind.IMAGE, ClassificationStatus.UNAVAILABLE)
        assertEquals(FinalAction.UNKNOWN, decide(unavailable))
        assertEquals(FinalAction.UNKNOWN, decide(unavailable, policy(DetectionMode.STRICT)))
    }

    @Test fun protectionOrAiOffAllows() {
        assertEquals(FinalAction.ALLOW, decide(image(AiLabel.GORE, 0.99), policy(on = false)))
        assertEquals(FinalAction.ALLOW, decide(image(AiLabel.GORE, 0.99), policy(ai = false)))
    }

    @Test fun softmaxSexualAndNudityAddUpToTheSexualCategory() {
        val c = AiClassification.fromProbabilities(mapOf(AiLabel.SEXUAL to 0.48, AiLabel.NUDITY to 0.47, AiLabel.SAFE to 0.05), "test@1", 0.4)
        val r = ShieldScores.toResult(c, blockSuggestive = false)
        assertEquals(0.95, r.score(Category.SEXUAL), 1e-9)
        assertEquals(FinalAction.BLOCK, decide(c))
    }

    @Test fun textScoresKeepTheirOwnValuesAndConfidenceIsTheModelOutput() {
        val text = AiClassification.fromText(ClassificationResult(ClassificationStatus.OK, mapOf(Category.GAMBLING to 0.93, Category.DRUGS to 0.2, Category.SAFE to 0.05), "sg-text-1"))
        assertEquals(AiLabel.GAMBLING, text.label)
        assertEquals(0.93, text.confidence, 1e-9)
        assertEquals("sg-text-1", text.modelVersion)
        assertFalse(text.derived)
        val safe = AiClassification.fromText(ClassificationResult(ClassificationStatus.OK, mapOf(Category.GAMBLING to 0.1, Category.SAFE to 0.9), "sg-text-1"))
        assertEquals(AiLabel.SAFE, safe.label)
        assertTrue("SAFE confidence of a text model is derived", safe.derived)
        val uncertain = AiClassification.fromText(ClassificationResult(ClassificationStatus.UNCERTAIN, mapOf(Category.GAMBLING to 0.6), "sg-text-1"))
        assertEquals(AiLabel.UNKNOWN, uncertain.label)
        assertEquals(0.6, uncertain.confidence, 1e-9)
    }

    @Test fun temporalConfirmationFollowsTheSpecExample() {
        fun r(s: Double) = ClassificationResult(ClassificationStatus.OK, mapOf(Category.SEXUAL to s, Category.SAFE to 1 - s), "test@1")
        val strict = policy(DetectionMode.STRICT)
        val c = TemporalConfirmer()
        fun act(t: Long, s: Double, p: DecisionPolicy) = ShieldPolicy.decide(RuleSignal.None, c.add(t, r(s)), image(AiLabel.SEXUAL, s), p).decision.action
        assertEquals(FinalAction.UNKNOWN, act(0, 0.55, strict)) // pending
        assertEquals(FinalAction.UNKNOWN, act(1000, 0.72, strict)) // evidence 0.55
        assertEquals(FinalAction.BLOCK, act(2000, 0.94, strict)) // evidence 0.72 ≥ 0.70

        val normal = policy(DetectionMode.NORMAL)
        c.reset()
        assertEquals(FinalAction.UNKNOWN, act(0, 0.55, normal))
        assertEquals(FinalAction.UNKNOWN, act(1000, 0.72, normal))
        assertEquals(FinalAction.UNKNOWN, act(2000, 0.94, normal)) // 0.72 < 0.90
        assertEquals(FinalAction.BLOCK, act(3000, 0.93, normal)) // two samples ≥ 0.90
    }

    @Test fun temporalConfirmationInstantSafeWindowAndReset() {
        fun r(s: Double, status: ClassificationStatus = ClassificationStatus.OK) =
            ClassificationResult(status, mapOf(Category.GORE to s, Category.SAFE to 1 - s), "test@1")
        val c = TemporalConfirmer(windowMs = 5_000, confirmations = 2, instant = 0.97)
        assertEquals(ClassificationStatus.OK, c.add(0, r(0.99)).status) // instant
        c.reset()
        assertEquals(ClassificationStatus.OK, c.add(0, r(0.10)).status) // clearly safe passes through
        assertEquals(ClassificationStatus.UNCERTAIN, c.add(100, r(0.8)).status)
        assertEquals(0.8, c.add(200, r(0.85)).score(Category.GORE), 1e-9) // min of 0.8, 0.85
        // Outside the window the old sample no longer counts.
        assertEquals(ClassificationStatus.UNCERTAIN, c.add(20_000, r(0.9)).status)
        // A non-OK result breaks the streak.
        c.add(20_100, r(0.0, ClassificationStatus.UNAVAILABLE))
        assertEquals(ClassificationStatus.UNCERTAIN, c.add(20_200, r(0.9)).status)
    }
}
