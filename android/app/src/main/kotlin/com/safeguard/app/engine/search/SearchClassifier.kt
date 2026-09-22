package com.safeguard.app.engine.search

import com.safeguard.app.engine.rules.Category

/** Per-category scores for one query, plus the rules that fired. */
data class SearchClassification(
    /** 0..1 per category; absent means 0. */
    val scores: Map<Category, Double>,
    /** Rule ids that matched (never the matched text). */
    val matchedRuleIds: List<String>,
    /** "keyword" for the rule layer; "ai" for a Phase 4 model. */
    val ruleType: String,
) {
    fun score(category: Category): Double = scores[category] ?: 0.0

    companion object {
        fun unknown(ruleType: String = RULE_TYPE_KEYWORD) = SearchClassification(emptyMap(), emptyList(), ruleType)
        const val RULE_TYPE_KEYWORD = "keyword"
    }
}

/**
 * Classifies a normalised query. Phase 3 ships [RuleBasedSearchClassifier];
 * Phase 4 adds an on-device model behind this same interface (and may
 * combine both with [CombinedSearchClassifier]).
 */
fun interface SearchClassifier {
    fun classify(query: NormalizedQuery): SearchClassification
}

/**
 * Lexicon-based classifier.
 *
 * Matching is by whole tokens and token sequences — never substrings — so
 * "Essex" does not match "sex" and "casinos" matches only if listed.
 * Scores per category are the strongest matching rule plus a small bonus
 * for additional distinct rules, capped at 1. A safe context term (e.g.
 * "education", "علاج") multiplies every score by its factor.
 */
class RuleBasedSearchClassifier(
    entries: List<LexiconEntry> = BuiltInSearchLexicon.entries,
    safeContexts: List<SafeContext> = BuiltInSearchLexicon.safeContexts,
) : SearchClassifier {

    private class Compiled(val entry: LexiconEntry, val tokens: List<String>)

    /** First token → rules starting with it: one hash lookup per token. */
    private val index: Map<String, List<Compiled>> = entries
        .map { Compiled(it, SearchNormalizer.normalizeTerm(it.phrase)) }
        .filter { it.tokens.isNotEmpty() }
        .groupBy { it.tokens.first() }

    private val contexts: Map<String, Double> = safeContexts
        .associate { (SearchNormalizer.normalizeTerm(it.phrase).firstOrNull() ?: "") to it.factor }
        .filterKeys { it.isNotEmpty() }

    override fun classify(query: NormalizedQuery): SearchClassification {
        if (query.isEmpty) return SearchClassification.unknown()
        val tokenVariants = query.tokens.map(SearchNormalizer::variants)

        val hits = LinkedHashMap<String, LexiconEntry>()
        for (i in tokenVariants.indices) {
            for (variant in tokenVariants[i]) {
                val candidates = index[variant] ?: continue
                for (c in candidates) {
                    if (matchesAt(c.tokens, tokenVariants, i)) hits[c.entry.id] = c.entry
                }
            }
        }
        if (hits.isEmpty()) return SearchClassification.unknown()

        var damp = 1.0
        for (variants in tokenVariants) {
            for (v in variants) contexts[v]?.let { damp = minOf(damp, it) }
        }

        val scores = hits.values.groupBy { it.category }.mapValues { (_, rules) ->
            val weights = rules.map { it.weight }.sortedDescending()
            val combined = weights.first() + 0.15 * (weights.size - 1)
            (combined.coerceAtMost(1.0) * damp)
        }
        return SearchClassification(scores, hits.keys.toList(), SearchClassification.RULE_TYPE_KEYWORD)
    }

    private fun matchesAt(phrase: List<String>, tokens: List<Set<String>>, start: Int): Boolean {
        if (start + phrase.size > tokens.size) return false
        for (k in phrase.indices) {
            if (phrase[k] !in tokens[start + k]) return false
        }
        return true
    }
}

/** Takes, per category, the highest score from several classifiers. */
class CombinedSearchClassifier(private val classifiers: List<SearchClassifier>) : SearchClassifier {
    override fun classify(query: NormalizedQuery): SearchClassification {
        val results = classifiers.map { it.classify(query) }
        val scores = HashMap<Category, Double>()
        for (r in results) r.scores.forEach { (c, s) -> scores[c] = maxOf(scores[c] ?: 0.0, s) }
        val top = results.maxByOrNull { r -> r.scores.values.maxOrNull() ?: 0.0 }
        return SearchClassification(scores, results.flatMap { it.matchedRuleIds }, top?.ruleType ?: "combined")
    }
}
