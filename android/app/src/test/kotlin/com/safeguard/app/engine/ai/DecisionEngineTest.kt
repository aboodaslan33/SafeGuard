package com.safeguard.app.engine.ai

import com.safeguard.app.engine.ai.MockClassifierAdapter.Companion.result
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Category.DANGEROUS
import com.safeguard.app.engine.rules.Category.DRUGS
import com.safeguard.app.engine.rules.Category.GAMBLING
import com.safeguard.app.engine.rules.Category.GORE
import com.safeguard.app.engine.rules.Category.SAFE
import com.safeguard.app.engine.rules.Category.SEXUAL
import com.safeguard.app.engine.rules.Category.UNKNOWN
import com.safeguard.app.engine.rules.Category.VIOLENCE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DecisionEngineTest {
    private val all = Category.filterable.toSet()
    private fun policy(
        ai: AiSettings = AiSettings(),
        categories: Set<Category> = all,
        enabled: Boolean = true,
        conflict: ConflictPolicy = ConflictPolicy(),
    ) = DecisionPolicy(enabled, categories, ai, conflict)

    private fun decide(ai: ClassificationResult?, p: DecisionPolicy = policy(), rule: RuleSignal = RuleSignal.None) =
        ProtectionDecisionEngine.decide(rule, ai, p, EventSource.SEARCH)

    // ---- categories ----------------------------------------------------

    @Test fun everyRiskCategoryBlocksAtHighConfidence() {
        for (c in listOf(SEXUAL, VIOLENCE, GORE, GAMBLING, DRUGS, DANGEROUS)) {
            val d = decide(result(c to 0.97))
            assertEquals(c.id, FinalAction.BLOCK, d.action)
            assertEquals(c, d.category)
            assertEquals(DecidedBy.AI, d.decidedBy)
            assertEquals(0.97, d.confidence, 1e-9)
        }
    }

    @Test fun safeContentIsAllowedAsSafe() {
        val d = decide(result(SEXUAL to 0.02, VIOLENCE to 0.01))
        assertEquals(FinalAction.ALLOW, d.action)
        assertEquals(SAFE, d.category)
        assertEquals("ai_safe", d.reason)
        assertTrue(d.confidence > 0.95)
    }

    @Test fun specExampleSexual097AtThreshold090Blocks() {
        val d = decide(result(SEXUAL to 0.97, VIOLENCE to 0.01, GORE to 0.0))
        assertEquals(FinalAction.BLOCK, d.action)
        assertEquals(SEXUAL, d.category)
    }

    // ---- confidence / thresholds / UNKNOWN -------------------------------

    @Test fun lowConfidenceIsUnknownNotBlocked() {
        val d = decide(result(SEXUAL to 0.62))
        assertEquals(FinalAction.UNKNOWN, d.action)
        assertEquals("below_threshold", d.reason)
        assertFalse(d.blocks)
    }

    @Test fun veryLowScoresAreSafe() {
        assertEquals(FinalAction.ALLOW, decide(result(SEXUAL to 0.3)).action)
    }

    @Test fun thresholdIsInclusiveAndPerCategory() {
        assertEquals(FinalAction.BLOCK, decide(result(SEXUAL to 0.90)).action)
        assertEquals(FinalAction.UNKNOWN, decide(result(SEXUAL to 0.8999)).action)
        // GORE's NORMAL threshold is 0.85.
        assertEquals(FinalAction.BLOCK, decide(result(GORE to 0.86)).action)
        assertEquals(FinalAction.UNKNOWN, decide(result(VIOLENCE to 0.86)).action)
    }

    @Test fun uncertainModelIsUnknownEvenWithHighScore() {
        val d = decide(result(SEXUAL to 0.99, status = ClassificationStatus.UNCERTAIN))
        assertEquals(FinalAction.UNKNOWN, d.action)
        assertEquals("ai_uncertain", d.reason)
    }

    @Test fun unavailableOrRejectedIsUnknown() {
        assertEquals("ai_unavailable", decide(ClassificationResult.unavailable(ClassificationError.NO_MODEL)).reason)
        assertEquals("input_rejected", decide(ClassificationResult.rejected(ClassificationError.MALFORMED)).reason)
        assertEquals(FinalAction.UNKNOWN, decide(ClassificationResult.unavailable(ClassificationError.RATE_LIMITED)).action)
    }

    @Test fun blockUnknownHookTurnsUnknownIntoBlock() {
        val p = policy(conflict = ConflictPolicy(blockUnknown = true))
        assertEquals(FinalAction.BLOCK, decide(result(SEXUAL to 0.6), p).action)
        assertEquals(FinalAction.ALLOW, decide(result(SEXUAL to 0.1), p).action)
    }

    // ---- multi-label ---------------------------------------------------

    @Test fun multiLabelReportsEveryExceededCategory() {
        val d = decide(result(SEXUAL to 0.91, VIOLENCE to 0.93))
        assertEquals(FinalAction.BLOCK, d.action)
        assertEquals(VIOLENCE, d.category)
        assertEquals(listOf(VIOLENCE, SEXUAL), d.exceeded)
    }

    @Test fun disabledCategoryIsDetectedButNotBlocked() {
        val d = decide(result(GAMBLING to 0.99), policy(categories = all - GAMBLING))
        assertEquals(FinalAction.ALLOW, d.action)
        assertEquals(listOf(GAMBLING), d.detected)
        assertTrue(d.exceeded.isEmpty())
    }

    @Test fun multiLabelWithOneDisabledCategoryBlocksOnTheEnabledOne() {
        val d = decide(result(SEXUAL to 0.95, VIOLENCE to 0.92), policy(categories = all - SEXUAL))
        assertEquals(FinalAction.BLOCK, d.action)
        assertEquals(VIOLENCE, d.category)
        assertEquals(listOf(SEXUAL, VIOLENCE), d.detected)
    }

    // ---- modes -----------------------------------------------------------

    @Test fun normalModeBlocksHighConfidenceOnly() {
        assertEquals(FinalAction.UNKNOWN, decide(result(SEXUAL to 0.75)).action)
    }

    @Test fun strictModeBlocksLowerScores() {
        val strict = policy(AiSettings(mode = DetectionMode.STRICT))
        assertEquals(FinalAction.BLOCK, decide(result(SEXUAL to 0.75), strict).action)
        assertEquals(FinalAction.UNKNOWN, decide(result(SEXUAL to 0.65), strict).action)
        for (c in Category.filterable) {
            assertTrue(c.id, ThresholdProfiles.STRICT.getValue(c) < ThresholdProfiles.NORMAL.getValue(c))
        }
    }

    @Test fun customModeUsesUserThresholdsClamped() {
        val custom = AiSettings(mode = DetectionMode.CUSTOM, customThresholds = mapOf(SEXUAL to 0.6, GAMBLING to 0.1, DRUGS to 2.0))
        assertEquals(0.6, custom.threshold(SEXUAL), 1e-9)
        assertEquals(ThresholdProfiles.MIN_CUSTOM, custom.threshold(GAMBLING), 1e-9)
        assertEquals(ThresholdProfiles.MAX_CUSTOM, custom.threshold(DRUGS), 1e-9)
        assertEquals(ThresholdProfiles.NORMAL.getValue(VIOLENCE), custom.threshold(VIOLENCE), 1e-9)
        assertEquals(FinalAction.BLOCK, decide(result(SEXUAL to 0.61), policy(custom)).action)
        assertEquals(FinalAction.UNKNOWN, decide(result(DRUGS to 0.98), policy(custom)).action)
    }

    @Test fun customThresholdNaNFallsBackToStrictestSafeValue() {
        val custom = AiSettings(mode = DetectionMode.CUSTOM, customThresholds = mapOf(SEXUAL to Double.NaN))
        assertEquals(ThresholdProfiles.MAX_CUSTOM, custom.threshold(SEXUAL), 1e-9)
    }

    @Test fun looseningDetection() {
        val normal = AiSettings()
        assertTrue(normal.isLoosenedBy(AiSettings.OFF))
        assertFalse(normal.isLoosenedBy(normal.copy(mode = DetectionMode.STRICT)))
        assertTrue(normal.copy(mode = DetectionMode.STRICT).isLoosenedBy(normal))
        assertTrue(normal.isLoosenedBy(AiSettings(mode = DetectionMode.CUSTOM, customThresholds = mapOf(SEXUAL to 0.95))))
        assertFalse(normal.isLoosenedBy(AiSettings(mode = DetectionMode.CUSTOM, customThresholds = mapOf(SEXUAL to 0.8))))
        assertFalse(AiSettings.OFF.isLoosenedBy(normal))
    }

    // ---- switches ----------------------------------------------------------

    @Test fun protectionOffAllowsEverything() {
        val d = decide(result(SEXUAL to 0.99), policy(enabled = false), RuleSignal.Block(SEXUAL, 1.0, "r"))
        assertEquals(FinalAction.ALLOW, d.action)
        assertEquals("protection_off", d.reason)
    }

    @Test fun aiOffKeepsPhase3Behaviour() {
        val d = decide(result(SEXUAL to 0.99), policy(AiSettings.OFF))
        assertEquals(FinalAction.ALLOW, d.action)
        assertEquals("ai_off", d.reason)
        assertEquals(FinalAction.BLOCK, decide(null, policy(AiSettings.OFF), RuleSignal.Block(SEXUAL, 1.0, "r")).action)
    }

    // ---- rule + AI conflicts ------------------------------------------------

    @Test fun knownBlockedRuleWinsWithoutAi() {
        val d = decide(result(SEXUAL to 0.0), rule = RuleSignal.Block(GAMBLING, 1.0, "ga01"))
        assertEquals(FinalAction.BLOCK, d.action)
        assertEquals(GAMBLING, d.category)
        assertEquals(DecidedBy.RULE, d.decidedBy)
        assertEquals("ga01", d.ruleId)
    }

    @Test fun ruleInDisabledCategoryFallsThroughToAi() {
        val d = decide(result(GAMBLING to 0.99), policy(categories = all - GAMBLING), RuleSignal.Block(GAMBLING, 1.0, "ga01"))
        assertEquals(FinalAction.ALLOW, d.action)
    }

    @Test fun explicitUserBlockIgnoresCategoryToggle() {
        val d = decide(null, policy(categories = emptySet()), RuleSignal.Block(DRUGS, 1.0, null, explicit = true))
        assertEquals(FinalAction.BLOCK, d.action)
    }

    @Test fun userAllowlistBeatsAi() {
        val d = decide(result(SEXUAL to 0.99), rule = RuleSignal.Allow(explicit = true))
        assertEquals(FinalAction.ALLOW, d.action)
        assertEquals("user_allowlist", d.reason)
    }

    @Test fun builtInSafeRuleBeatsAiByDefault_configurable() {
        val safeRule = RuleSignal.Allow(explicit = false)
        val kept = decide(result(SEXUAL to 0.97), rule = safeRule)
        assertEquals(FinalAction.ALLOW, kept.action)
        assertEquals("safe_rule_over_ai", kept.reason)
        assertEquals(listOf(SEXUAL), kept.exceeded)
        val overridden = decide(result(SEXUAL to 0.97), policy(conflict = ConflictPolicy(safeRuleWinsOverAi = false)), safeRule)
        assertEquals(FinalAction.BLOCK, overridden.action)
    }

    @Test fun decisionIsDeterministic() {
        val r = result(SEXUAL to 0.91, VIOLENCE to 0.91)
        val first = decide(r)
        repeat(20) { assertEquals(first, decide(r)) }
        assertEquals(SEXUAL, first.category) // ties keep category order
    }

    @Test fun unknownCategoryNeverBlocks() {
        val d = decide(result(UNKNOWN to 1.0))
        assertEquals(FinalAction.ALLOW, d.action)
    }
}
