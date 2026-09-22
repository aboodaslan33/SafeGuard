package com.safeguard.app.engine.rules

/**
 * Persistent rule storage. The Android implementation is SQLite
 * ([com.safeguard.app.data.SqliteRuleStore]); [InMemoryRuleStore] backs
 * unit tests. Implementations must be thread-safe.
 */
interface RuleStore {
    /** Enabled rules whose domain is exactly one of [domains]. */
    fun findEnabled(domains: Collection<String>): List<Rule>

    /** Inserts or replaces the rule identified by (domain, source). */
    fun upsert(rule: Rule)

    fun upsertAll(rules: Collection<Rule>)

    /** Deletes the rule (domain, source); returns true if one existed. */
    fun delete(domain: String, source: RuleSource): Boolean

    fun setEnabled(domain: String, source: RuleSource, enabled: Boolean): Boolean

    fun get(domain: String, source: RuleSource): Rule?

    fun list(source: RuleSource? = null, action: RuleAction? = null, limit: Int = 500, offset: Int = 0): List<Rule>

    /** Rules whose domain contains [query] (plain text, never a pattern). */
    fun search(query: String, limit: Int = 100): List<Rule>

    fun count(source: RuleSource? = null): Int

    /** Removes every rule from [source] (e.g. before re-seeding a list). */
    fun deleteSource(source: RuleSource)
}

class InMemoryRuleStore : RuleStore {
    private val rules = LinkedHashMap<Pair<String, RuleSource>, Rule>()

    @Synchronized
    override fun findEnabled(domains: Collection<String>): List<Rule> {
        val wanted = domains.toSet()
        return rules.values.filter { it.enabled && it.domain in wanted }
    }

    @Synchronized
    override fun upsert(rule: Rule) {
        rules[rule.domain to rule.source] = rule
    }

    @Synchronized
    override fun upsertAll(rules: Collection<Rule>) = rules.forEach(::upsert)

    @Synchronized
    override fun delete(domain: String, source: RuleSource): Boolean =
        rules.remove(domain to source) != null

    @Synchronized
    override fun setEnabled(domain: String, source: RuleSource, enabled: Boolean): Boolean {
        val key = domain to source
        val rule = rules[key] ?: return false
        rules[key] = rule.copy(enabled = enabled)
        return true
    }

    @Synchronized
    override fun get(domain: String, source: RuleSource): Rule? = rules[domain to source]

    @Synchronized
    override fun list(source: RuleSource?, action: RuleAction?, limit: Int, offset: Int): List<Rule> =
        rules.values
            .filter { (source == null || it.source == source) && (action == null || it.action == action) }
            .sortedBy { it.domain }
            .drop(offset)
            .take(limit)

    @Synchronized
    override fun search(query: String, limit: Int): List<Rule> =
        rules.values.filter { it.domain.contains(query.lowercase()) }.sortedBy { it.domain }.take(limit)

    @Synchronized
    override fun count(source: RuleSource?): Int =
        rules.values.count { source == null || it.source == source }

    @Synchronized
    override fun deleteSource(source: RuleSource) {
        rules.keys.removeAll { it.second == source }
    }
}
