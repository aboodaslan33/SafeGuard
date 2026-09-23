package com.safeguard.app.engine

import com.safeguard.app.engine.explain.DecisionExplainer
import com.safeguard.app.engine.explain.DecisionTrace
import com.safeguard.app.engine.explain.Explanation
import com.safeguard.app.engine.explain.Verdict
import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.logging.InMemoryBlockEventStore
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.DecisionReason
import com.safeguard.app.engine.rules.InMemoryRuleStore
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.search.SearchDecision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Phase 8: unified decision explanations and the content-free trace. */
class Phase8Test {
    private val policy = ProtectionPolicy.allCategories()

    @Test fun everyDomainReasonHasAnExplanationWithTheRightVerdict() {
        for (reason in DecisionReason.entries) {
            val action = when (reason) {
                DecisionReason.USER_BLOCKLIST, DecisionReason.CATEGORY_BLOCKED,
                DecisionReason.CLASSIFIED_BLOCKED, DecisionReason.UNKNOWN_BLOCKED_STRICT -> RuleAction.BLOCK
                else -> RuleAction.ALLOW
            }
            val e = DecisionExplainer.domain(Decision(action, Category.GAMBLING, reason, "x.test"))
            assertEquals(reason.name, action == RuleAction.BLOCK, e.verdict == Verdict.BLOCKED)
            assertTrue(DecisionExplainer.stages(e).isNotEmpty())
        }
    }

    @Test fun realEngineDecisionsExplainCorrectly() {
        val store = InMemoryRuleStore()
        store.upsert(Rule("mine.test", Category.CUSTOM, RuleAction.BLOCK, source = RuleSource.USER))
        store.upsert(Rule("casino.test", Category.GAMBLING, RuleAction.BLOCK, source = RuleSource.BUILT_IN))
        store.upsert(Rule("ok.casino.test", Category.UNKNOWN, RuleAction.ALLOW, source = RuleSource.USER))
        val engine = RuleEngine(store)
        fun explain(d: String) = DecisionExplainer.domain(engine.evaluate(d, policy))
        assertEquals(Explanation.USER_BLOCKED_DOMAIN, explain("mine.test"))
        assertEquals(Explanation.KNOWN_BLOCKED_DOMAIN, explain("www.casino.test"))
        assertEquals(Explanation.USER_ALLOWED, explain("ok.casino.test"))
        assertEquals(Explanation.NO_MATCH, explain("example.org"))
        assertEquals(
            Explanation.CATEGORY_DISABLED,
            DecisionExplainer.domain(engine.evaluate("casino.test", policy.copy(blockedCategories = emptySet()))),
        )
    }

    @Test fun searchAndAiDecisionsExplain() {
        fun s(ruleType: String, reason: String, action: RuleAction = RuleAction.BLOCK) =
            DecisionExplainer.search(SearchDecision(action, Category.GAMBLING, reason, 0.93, ruleType))
        assertEquals(Explanation.CUSTOM_KEYWORD, s("custom_keyword", "custom_keyword"))
        assertEquals(Explanation.SEARCH_RULE, s("keyword", "category_blocked"))
        assertEquals(Explanation.SEARCH_BELOW_THRESHOLD, s("keyword", "below_threshold", RuleAction.ALLOW))
        assertEquals(Explanation.AI_ABOVE_THRESHOLD, s("ai_text", "ai_threshold"))
        assertEquals(Explanation.AI_BELOW_THRESHOLD, s("ai_text", "below_threshold", RuleAction.ALLOW))
        assertEquals(Explanation.AI_UNAVAILABLE, s("ai_text", "ai_unavailable", RuleAction.ALLOW))
        assertEquals(Explanation.AI_UNCERTAIN, s("ai_text", "ai_uncertain", RuleAction.ALLOW))
    }

    @Test fun dnsBlockEventsKeepEnoughToExplainLater() {
        val store = InMemoryBlockEventStore()
        val logger = BlockLogger(store, { it.run() }, clock = { 1_000L })
        logger.onBlocked(Decision(RuleAction.BLOCK, Category.CUSTOM, DecisionReason.USER_BLOCKLIST, "mine.test"))
        logger.onBlocked(Decision(RuleAction.BLOCK, Category.GAMBLING, DecisionReason.CATEGORY_BLOCKED, "casino.test"))
        val byDomain = store.recent(10).associateBy { it.subject }
        assertEquals(
            Explanation.USER_BLOCKED_DOMAIN,
            DecisionExplainer.event(EventSource.DNS, byDomain.getValue("mine.test").ruleType),
        )
        assertEquals(
            Explanation.KNOWN_BLOCKED_DOMAIN,
            DecisionExplainer.event(EventSource.DNS, byDomain.getValue("casino.test").ruleType),
        )
        // Older events (Phase 2–7 "domain") still explain.
        assertEquals(Explanation.KNOWN_BLOCKED_DOMAIN, DecisionExplainer.event(EventSource.DNS, BlockEvent.RULE_TYPE_DOMAIN))
        assertEquals(Explanation.PROTECTED_APP, DecisionExplainer.event(EventSource.APP, BlockEvent.RULE_TYPE_PROTECTED_APP))
    }

    @Test fun explanationIdsAreUniqueAndRoundTrip() {
        val ids = Explanation.entries.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        for (e in Explanation.entries) assertEquals(e, Explanation.fromId(e.id))
    }

    @Test fun traceIsOffByDefaultBoundedAndContentFree() {
        val trace = DecisionTrace(capacity = 3)
        val d = Decision(RuleAction.BLOCK, Category.GAMBLING, DecisionReason.CATEGORY_BLOCKED, "secret-casino.test")
        trace.recordDomain(d, 1)
        assertTrue(trace.snapshot().isEmpty())

        trace.enabled = true
        repeat(5) { trace.recordDomain(d, it.toLong()) }
        trace.recordSearch(SearchDecision(RuleAction.BLOCK, Category.DRUGS, "ai_threshold", 0.937, "ai_text"), 9)
        val entries = trace.snapshot()
        assertEquals(3, entries.size)
        assertEquals(EventSource.AI, entries.first().source)
        assertEquals(90, entries.first().confidenceBucket)
        // No field can hold the domain or query.
        assertFalse(entries.toString().contains("secret"))

        trace.enabled = false
        assertTrue(trace.snapshot().isEmpty())
    }
}
