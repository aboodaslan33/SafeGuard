package com.safeguard.app.engine.search

import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.RuleAction

/** A search the user typed, as far as it can ever be known. */
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
)

/**
 * Search filtering seam (Phase 3+).
 *
 * DNS filtering can't see search queries: they travel inside HTTPS. A real
 * implementation will classify queries from a source that legitimately
 * has them (e.g. SafeSearch enforcement via DNS, or a future on-device
 * classifier). Nothing is implemented in Phase 2.
 */
interface SearchFilterService {
    fun classify(query: SearchQuery): SearchDecision

    /** Whether this service actually filters anything. */
    val isActive: Boolean
}

/** Phase 2 placeholder: allows everything and reports itself inactive. */
object NoOpSearchFilterService : SearchFilterService {
    override val isActive = false

    override fun classify(query: SearchQuery) =
        SearchDecision(RuleAction.ALLOW, Category.UNKNOWN, "search filtering not implemented")
}
