package com.safeguard.app.engine.rules

import com.safeguard.app.engine.domain.DomainName

/** What to do with a domain that no rule and no classifier knows. */
enum class UnknownDomainPolicy {
    /** Default and the only mode exposed in Phase 2. */
    ALLOW,

    /** Reserved for a future opt-in "Strict Mode"; not reachable from the UI. */
    BLOCK,
}

/** Immutable snapshot of the user's protection settings. */
data class ProtectionPolicy(
    val enabled: Boolean,
    val blockedCategories: Set<Category>,
    val unknownDomains: UnknownDomainPolicy = UnknownDomainPolicy.ALLOW,
) {
    companion object {
        val DISABLED = ProtectionPolicy(enabled = false, blockedCategories = emptySet())
        fun allCategories(enabled: Boolean = true) =
            ProtectionPolicy(enabled, Category.filterable.toSet())
    }
}

enum class DecisionReason {
    PROTECTION_OFF,
    INVALID_DOMAIN,
    ALLOWLISTED,
    USER_BLOCKLIST,
    CATEGORY_BLOCKED,
    CATEGORY_DISABLED,
    SAFE_RULE,
    CLASSIFIED_BLOCKED,
    UNKNOWN_ALLOWED,
    UNKNOWN_BLOCKED_STRICT,
}

data class Decision(
    val action: RuleAction,
    val category: Category,
    val reason: DecisionReason,
    /** The normalised domain that was evaluated (null if malformed). */
    val domain: String?,
    val matchedRule: Rule? = null,
) {
    val isBlocked: Boolean get() = action == RuleAction.BLOCK
}

/**
 * Future hook for classifying domains no rule covers (on-device model,
 * remote lookup…). Phase 2 ships [None], so unknown stays unknown.
 */
fun interface DomainClassifier {
    fun classify(domain: String): Category

    companion object {
        val None = DomainClassifier { Category.UNKNOWN }
    }
}

/**
 * Decides ALLOW / BLOCK for a domain.
 *
 * Precedence, highest first:
 *  1. Protection off → ALLOW.
 *  2. User allowlist → ALLOW, even over a block. An entry covers its
 *     subdomains only if it was added with `includeSubdomains`; otherwise
 *     just the domain and its `www.` alias.
 *  3. User blocklist (domain or any parent) → BLOCK. User blocks apply
 *     whatever the category toggles, because they are explicit intent.
 *  4. Most specific list rule: SAFE/ALLOW → ALLOW; otherwise BLOCK only if
 *     its category is enabled.
 *  5. Classifier (Phase 2: none).
 *  6. Unknown → [ProtectionPolicy.unknownDomains] (ALLOW by default).
 *
 * Lookups hit the store once per distinct domain (one indexed query over
 * the suffix candidates) and are cached in a bounded LRU. The cache holds
 * matching *rules*, not decisions, so category toggles take effect
 * without invalidation.
 */
class RuleEngine(
    private val store: RuleStore,
    private val classifier: DomainClassifier = DomainClassifier.None,
    cacheSize: Int = 4096,
) {
    private val cache = LruCache<String, List<Rule>>(cacheSize)

    fun evaluate(rawDomain: String, policy: ProtectionPolicy): Decision {
        if (!policy.enabled) {
            return Decision(RuleAction.ALLOW, Category.UNKNOWN, DecisionReason.PROTECTION_OFF, null)
        }
        val domain = DomainName.normalizeQueryName(rawDomain)
            ?: return Decision(RuleAction.ALLOW, Category.UNKNOWN, DecisionReason.INVALID_DOMAIN, null)

        val matches = matchesFor(domain).filter { it.covers(domain) }

        mostSpecific(matches.filter { it.source == RuleSource.USER && it.action == RuleAction.ALLOW })?.let {
            return Decision(RuleAction.ALLOW, it.category, DecisionReason.ALLOWLISTED, domain, it)
        }
        mostSpecific(matches.filter { it.source == RuleSource.USER && it.action == RuleAction.BLOCK })?.let {
            return Decision(RuleAction.BLOCK, it.category, DecisionReason.USER_BLOCKLIST, domain, it)
        }

        val listRule = mostSpecific(matches.filter { it.source != RuleSource.USER })
        if (listRule != null) {
            return when {
                listRule.action == RuleAction.ALLOW || listRule.category == Category.SAFE ->
                    Decision(RuleAction.ALLOW, listRule.category, DecisionReason.SAFE_RULE, domain, listRule)
                listRule.category in policy.blockedCategories ->
                    Decision(RuleAction.BLOCK, listRule.category, DecisionReason.CATEGORY_BLOCKED, domain, listRule)
                else ->
                    Decision(RuleAction.ALLOW, listRule.category, DecisionReason.CATEGORY_DISABLED, domain, listRule)
            }
        }

        val classified = classifier.classify(domain)
        if (classified.isFilterable) {
            return if (classified in policy.blockedCategories) {
                Decision(RuleAction.BLOCK, classified, DecisionReason.CLASSIFIED_BLOCKED, domain)
            } else {
                Decision(RuleAction.ALLOW, classified, DecisionReason.CATEGORY_DISABLED, domain)
            }
        }

        return when (policy.unknownDomains) {
            UnknownDomainPolicy.ALLOW ->
                Decision(RuleAction.ALLOW, Category.UNKNOWN, DecisionReason.UNKNOWN_ALLOWED, domain)
            UnknownDomainPolicy.BLOCK ->
                Decision(RuleAction.BLOCK, Category.UNKNOWN, DecisionReason.UNKNOWN_BLOCKED_STRICT, domain)
        }
    }

    /** Call after any rule change. */
    fun invalidate() = cache.clear()

    private fun matchesFor(domain: String): List<Rule> {
        cache.get(domain)?.let { return it }
        val found = store.findEnabled(DomainName.matchCandidates(domain))
        cache.put(domain, found)
        return found
    }

    /** Longest domain wins; on a tie BLOCK beats ALLOW (fail closed). */
    private fun mostSpecific(rules: List<Rule>): Rule? =
        rules.maxWithOrNull(compareBy<Rule>({ it.domain.length }, { it.action == RuleAction.BLOCK }))
}

/** Small thread-safe LRU on top of LinkedHashMap's access order. */
class LruCache<K, V>(private val maxSize: Int) {
    private val map = object : LinkedHashMap<K, V>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?) = size > maxSize
    }

    @Synchronized fun get(key: K): V? = map[key]
    @Synchronized fun put(key: K, value: V) { map[key] = value }
    @Synchronized fun clear() = map.clear()
    @Synchronized fun size(): Int = map.size
}
