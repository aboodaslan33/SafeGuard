package com.safeguard.app.engine.search

import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.RuleAction

/** A search the user submitted. The text never leaves this layer. */
data class SearchQuery(
    /** e.g. "google", "bing", "youtube". */
    val engine: String,
    val text: String,
    val locale: String? = null,
)

data class SearchDecision(
    val action: RuleAction,
    val category: Category,
    val reason: String,
    /** 0..1; 0 for ALLOW without any signal. */
    val confidence: Double = 0.0,
    val ruleType: String = SearchClassification.RULE_TYPE_KEYWORD,
    /** The strongest matching rule id (never the query text). */
    val ruleId: String? = null,
)

/** Search protection settings. Categories are shared with DNS filtering. */
data class SearchPolicyConfig(
    val enabled: Boolean,
    val blockedCategories: Set<Category>,
    /** Score at or above which an enabled category blocks. */
    val thresholds: Map<Category, Double> = emptyMap(),
    val defaultThreshold: Double = DEFAULT_THRESHOLD,
) {
    fun threshold(c: Category) = thresholds[c] ?: defaultThreshold

    companion object {
        const val DEFAULT_THRESHOLD = 0.6
        val DISABLED = SearchPolicyConfig(false, emptySet())
    }
}

/**
 * Turns a classification into a decision. Among enabled categories whose
 * score reaches their threshold, the highest score wins. UNKNOWN (no
 * signal) and SAFE always allow.
 */
object SearchPolicy {
    fun decide(c: SearchClassification, config: SearchPolicyConfig): SearchDecision {
        if (!config.enabled) {
            return SearchDecision(RuleAction.ALLOW, Category.UNKNOWN, "search_protection_off", 0.0, c.ruleType)
        }
        val candidates = c.scores.filterKeys { it.isFilterable }
        if (candidates.isEmpty()) {
            return SearchDecision(RuleAction.ALLOW, Category.UNKNOWN, "unknown", 0.0, c.ruleType)
        }
        val blocking = candidates
            .filter { (cat, score) -> cat in config.blockedCategories && score >= config.threshold(cat) }
            .maxByOrNull { it.value }
        val ruleId = c.matchedRuleIds.firstOrNull()
        if (blocking != null) {
            return SearchDecision(RuleAction.BLOCK, blocking.key, "category_blocked", blocking.value, c.ruleType, ruleId)
        }
        val top = candidates.maxBy { it.value }
        val reason = if (top.key in config.blockedCategories) "below_threshold" else "category_disabled"
        return SearchDecision(RuleAction.ALLOW, top.key, reason, top.value, c.ruleType, ruleId)
    }
}

/** Receives the outcome of each classified search (for privacy-safe logging). */
fun interface SearchDecisionListener {
    fun onDecision(query: SearchQuery, decision: SearchDecision)
}

/**
 * Search filtering entry point.
 *
 * Analysis runs once per *submitted* query (never per keystroke). The
 * query text is used in memory only; listeners receive it so they can
 * derive a keyed hash, and must not store it.
 */
interface SearchFilterService {
    fun classify(query: SearchQuery): SearchDecision

    /** Whether this service actually filters anything. */
    val isActive: Boolean
}

class RuleBasedSearchFilterService(
    private val classifier: SearchClassifier,
    private val config: () -> SearchPolicyConfig,
    private val listener: SearchDecisionListener = SearchDecisionListener { _, _ -> },
) : SearchFilterService {
    override val isActive: Boolean get() = config().enabled

    override fun classify(query: SearchQuery): SearchDecision {
        val decision = SearchPolicy.decide(classifier.classify(SearchNormalizer.normalize(query.text)), config())
        listener.onDecision(query, decision)
        return decision
    }
}

/** Placeholder kept for platforms without the native engine. */
object NoOpSearchFilterService : SearchFilterService {
    override val isActive = false

    override fun classify(query: SearchQuery) =
        SearchDecision(RuleAction.ALLOW, Category.UNKNOWN, "search filtering not implemented")
}
