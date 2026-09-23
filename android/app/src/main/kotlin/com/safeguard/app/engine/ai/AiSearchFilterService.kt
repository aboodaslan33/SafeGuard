package com.safeguard.app.engine.ai

import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.search.SearchClassifier
import com.safeguard.app.engine.search.SearchDecision
import com.safeguard.app.engine.search.SearchDecisionListener
import com.safeguard.app.engine.search.SearchFilterService
import com.safeguard.app.engine.search.SearchNormalizer
import com.safeguard.app.engine.search.SearchPolicy
import com.safeguard.app.engine.search.SearchPolicyConfig
import com.safeguard.app.engine.search.SearchQuery

/** Receives every decision the AI took part in (for aggregate counters). */
fun interface AiDecisionListener {
    fun onAiDecision(kind: ContentKind, decision: ProtectionDecision)
}

/**
 * Search filtering = rule layer first, AI second (the rule engine is kept,
 * not replaced):
 *
 * - a known blocked query (lexicon score ≥ threshold, category enabled)
 *   → BLOCK immediately; the model is not run;
 * - otherwise, if AI Protection is on → on-device text model →
 *   [ProtectionDecisionEngine] → BLOCK / UNKNOWN (allowed) / ALLOW.
 *
 * Runs once per submitted query. The text stays in memory.
 */
class AiSearchFilterService(
    private val rules: SearchClassifier,
    private val config: () -> SearchPolicyConfig,
    private val ai: ContentClassifier,
    private val aiSettings: () -> AiSettings,
    private val listener: SearchDecisionListener = SearchDecisionListener { _, _ -> },
    private val aiListener: AiDecisionListener = AiDecisionListener { _, _ -> },
) : SearchFilterService {

    override val isActive: Boolean get() = config().enabled

    override fun classify(query: SearchQuery): SearchDecision {
        val cfg = config()
        val decision = decide(query, cfg)
        listener.onDecision(query, decision)
        return decision
    }

    private fun decide(query: SearchQuery, cfg: SearchPolicyConfig): SearchDecision {
        val ruleDecision = SearchPolicy.decide(rules.classify(SearchNormalizer.normalize(query.text)), cfg)
        if (!cfg.enabled || ruleDecision.action == RuleAction.BLOCK) return ruleDecision

        val settings = aiSettings()
        if (!settings.enabled) return ruleDecision

        val result = ai.classifyText(query.text)
        val d = ProtectionDecisionEngine.decide(
            rule = RuleSignal.None,
            ai = result,
            policy = DecisionPolicy(true, cfg.blockedCategories, settings),
            source = EventSource.SEARCH,
        )
        aiListener.onAiDecision(ContentKind.TEXT, d)
        return SearchDecision(
            action = if (d.blocks) RuleAction.BLOCK else RuleAction.ALLOW,
            category = d.category,
            reason = d.reason,
            confidence = d.confidence,
            ruleType = RULE_TYPE_AI_TEXT,
            ruleId = d.modelId,
        )
    }

    companion object {
        const val RULE_TYPE_AI_TEXT = "ai_text"
        const val RULE_TYPE_AI_IMAGE = "ai_image"
    }
}

/** Updates aggregate AI counters. Never sees the content. */
class AiStatsRecorder(private val store: AiStatsStore) : AiDecisionListener {
    override fun onAiDecision(kind: ContentKind, decision: ProtectionDecision) {
        val blocked = decision.category.takeIf { decision.blocks && decision.decidedBy == DecidedBy.AI }
        if (decision.detected.isEmpty() && blocked == null) return
        store.record(decision.detected, blocked)
    }
}
