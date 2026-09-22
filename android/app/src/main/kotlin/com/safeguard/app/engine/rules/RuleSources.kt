package com.safeguard.app.engine.rules

import com.safeguard.app.engine.domain.DomainName

/**
 * Rules shipped inside the app.
 *
 * Deliberately tiny: SafeGuard does not embed third-party adult/gambling
 * lists in source code. Real category lists arrive through a
 * [RemoteRuleSource] in a later phase and are stored in the same database.
 */
object BuiltInRules {
    /** Bump when the list changes; the store re-seeds on a new version. */
    const val VERSION = 1

    /** Always seeded. Documentation domains reserved by IANA (RFC 2606). */
    fun production(now: Long): List<Rule> = listOf(
        Rule("example.com", Category.SAFE, RuleAction.ALLOW, source = RuleSource.BUILT_IN, version = VERSION, updatedAt = now),
    )

    /**
     * Debug builds only: IANA documentation domains mapped to categories so
     * blocking can be verified on a device without touching real sites.
     * `*.safeguard.test` never resolves publicly (RFC 6761) and is used by
     * unit tests.
     */
    fun testFixtures(now: Long): List<Rule> = listOf(
        Rule("example.org", Category.SEXUAL, RuleAction.BLOCK, source = RuleSource.TEST, version = VERSION, updatedAt = now),
        Rule("example.net", Category.GAMBLING, RuleAction.BLOCK, source = RuleSource.TEST, version = VERSION, updatedAt = now),
        Rule("violence.safeguard.test", Category.VIOLENCE, RuleAction.BLOCK, source = RuleSource.TEST, version = VERSION, updatedAt = now),
        Rule("gore.safeguard.test", Category.GORE, RuleAction.BLOCK, source = RuleSource.TEST, version = VERSION, updatedAt = now),
        Rule("drugs.safeguard.test", Category.DRUGS, RuleAction.BLOCK, source = RuleSource.TEST, version = VERSION, updatedAt = now),
        Rule("dangerous.safeguard.test", Category.DANGEROUS, RuleAction.BLOCK, source = RuleSource.TEST, version = VERSION, updatedAt = now),
    )
}

/**
 * A provider of rule lists. Phase 2 has only built-ins; a remote source
 * (signed, versioned list downloads) plugs in here later.
 */
interface RuleSourceProvider {
    val source: RuleSource
    val version: Int
    fun load(now: Long): List<Rule>
}

/** Future: download + verify + import category lists. Not implemented. */
interface RemoteRuleSource : RuleSourceProvider {
    /** Returns the newest available list version without downloading it. */
    fun latestVersion(): Int?
}

/**
 * Parses hosts-file style lists (`0.0.0.0 domain`, `127.0.0.1 domain`, or a
 * bare domain per line) so imported lists never need custom code. Invalid
 * lines are skipped, never guessed at.
 */
object HostsListParser {
    fun parse(
        text: Sequence<String>,
        category: Category,
        source: RuleSource,
        version: Int,
        now: Long,
    ): Sequence<Rule> = text.mapNotNull { line ->
        val content = line.substringBefore('#').trim()
        if (content.isEmpty()) return@mapNotNull null
        val parts = content.split(Regex("\\s+"))
        val host = when {
            parts.size >= 2 && (parts[0] == "0.0.0.0" || parts[0] == "127.0.0.1" || parts[0] == "::") -> parts[1]
            parts.size == 1 -> parts[0]
            else -> return@mapNotNull null
        }
        if (host == "localhost" || host.endsWith(".localdomain")) return@mapNotNull null
        val domain = DomainName.parseRuleDomain(host) ?: return@mapNotNull null
        Rule(domain, category, RuleAction.BLOCK, source = source, version = version, updatedAt = now)
    }
}
