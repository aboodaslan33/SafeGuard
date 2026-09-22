package com.safeguard.app.engine.privacy

import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.search.SearchDecision
import com.safeguard.app.engine.search.SearchDecisionListener
import com.safeguard.app.engine.search.SearchNormalizer
import com.safeguard.app.engine.search.SearchQuery

/**
 * Turns search decisions into privacy-safe events.
 *
 * Only BLOCK decisions are recorded. The stored subject is
 * `<rule id>#<keyed short hash>`, e.g. `ga07#3fa1c09e`: enough to see that
 * the same rule fired again, not enough to recover the query. The query
 * text, the search engine and the locale are never stored.
 */
class SearchEventRecorder(
    private val logger: BlockLogger,
    private val hasher: QueryHasher,
) : SearchDecisionListener {
    override fun onDecision(query: SearchQuery, decision: SearchDecision) {
        if (decision.action != RuleAction.BLOCK) return
        val hash = hasher.shortHash(SearchNormalizer.normalize(query.text).text)
        logger.record(
            BlockEvent(
                timestamp = logger.now(),
                subject = "${decision.ruleId ?: "rule"}#$hash",
                category = decision.category,
                source = EventSource.SEARCH,
                action = RuleAction.BLOCK,
                confidence = decision.confidence.coerceIn(0.0, 1.0),
                ruleType = decision.ruleType,
            ),
        )
    }
}
