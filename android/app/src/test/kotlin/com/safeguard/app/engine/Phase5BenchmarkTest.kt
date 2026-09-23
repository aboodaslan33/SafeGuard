package com.safeguard.app.engine

import com.safeguard.app.engine.apps.AccessibilityState
import com.safeguard.app.engine.dns.DnsMessage
import com.safeguard.app.engine.dns.DnsPacketFilter
import com.safeguard.app.engine.dns.Ipv4Udp
import com.safeguard.app.engine.health.HealthInputs
import com.safeguard.app.engine.health.ProtectionHealthEvaluator
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.rules.RuleStore
import com.safeguard.app.engine.search.CustomKeywords
import com.safeguard.app.engine.search.InMemoryCustomKeywordStore
import com.safeguard.app.engine.search.SearchNormalizer
import com.safeguard.app.engine.status.VpnState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Hash-indexed rule store for benchmarks: models the SQLite store's
 * indexed `domain IN (…)` lookup (InMemoryRuleStore scans linearly).
 */
private class IndexedRuleStore(rules: List<Rule>) : RuleStore {
    private val byDomain = rules.groupBy { it.domain }
    override fun findEnabled(domains: Collection<String>) = domains.flatMap { byDomain[it].orEmpty() }.filter { it.enabled }
    override fun upsert(rule: Rule) = throw UnsupportedOperationException()
    override fun upsertAll(rules: Collection<Rule>) = throw UnsupportedOperationException()
    override fun delete(domain: String, source: RuleSource) = false
    override fun setEnabled(domain: String, source: RuleSource, enabled: Boolean) = false
    override fun get(domain: String, source: RuleSource) = byDomain[domain]?.firstOrNull { it.source == source }
    override fun list(source: RuleSource?, action: RuleAction?, limit: Int, offset: Int) = emptyList<Rule>()
    override fun search(query: String, limit: Int) = emptyList<Rule>()
    override fun count(source: RuleSource?) = byDomain.size
    override fun deleteSource(source: RuleSource) = Unit
}

/**
 * Phase 5 performance measurements on the build machine's JVM — NOT a
 * phone, and not the SQLite-backed store. Written to
 * build/phase5-bench.txt and copied (labelled as such) into
 * docs/PHASE_5_REPORT.md. Assertions are loose regression ceilings.
 */
class Phase5BenchmarkTest {
    private fun <T> timeNs(runs: Int, block: (Int) -> T): Double {
        repeat(minOf(runs, 2_000)) { block(it) } // warm-up
        val start = System.nanoTime()
        for (i in 0 until runs) block(i)
        return (System.nanoTime() - start).toDouble() / runs
    }

    @Test fun benchmark() {
        val out = StringBuilder("JVM ${System.getProperty("java.version")}, ${Runtime.getRuntime().availableProcessors()} CPUs (build container, not a phone)\n")

        // --- Large rule list: 100 000 list rules + 2 000 user rules. ---
        val rules = ArrayList<Rule>()
        val categories = Category.filterable
        for (i in 0 until 100_000) {
            rules += Rule("site$i.example${i % 50}.test", categories[i % categories.size], RuleAction.BLOCK, source = RuleSource.BUILT_IN)
        }
        for (i in 0 until 2_000) rules += Rule("user$i.test", Category.CUSTOM, RuleAction.BLOCK, source = RuleSource.USER)
        val rt = Runtime.getRuntime()
        System.gc()
        val t0 = System.nanoTime()
        val engine = RuleEngine(IndexedRuleStore(rules), cacheSize = 4096)
        val buildMs = (System.nanoTime() - t0) / 1e6
        val policy = ProtectionPolicy.allCategories()
        out.append("rule set: ${rules.size} rules (index build %.0f ms, used heap ~%d MiB)\n"
            .format(buildMs, (rt.totalMemory() - rt.freeMemory()) / (1024 * 1024)))

        // Cold lookups: every name distinct (cache misses), deep subdomains.
        val cold = timeNs(50_000) { i -> engine.evaluate("a.b.c.q$i.site${i % 100_000}.example${i % 50}.test", policy) }
        // Hot lookups: the same few names (cache hits), like repeated page loads.
        val hot = timeNs(200_000) { i -> engine.evaluate("www.site${i % 100}.example${i % 50}.test", policy) }
        out.append("rule decision, cache miss: %.2f µs; cache hit: %.2f µs\n".format(cold / 1000, hot / 1000))
        assertEquals(RuleAction.BLOCK, engine.evaluate("x.site7.example7.test", policy).action)

        // --- Whole DNS packet path (parse IPv4/UDP + DNS, decide, build reply). ---
        val app = byteArrayOf(10, 111, 222.toByte(), 1)
        val dns = byteArrayOf(10, 111, 222.toByte(), 2)
        val filter = DnsPacketFilter(engine, { policy }, { })
        val packets = (0 until 1_000).map { i ->
            Ipv4Udp.build(app, dns, 40000, 53, DnsMessage.buildQuery(i, if (i % 2 == 0) "site$i.example${i % 50}.test" else "allowed$i.org", 1))
        }
        val perPacket = timeNs(200_000) { i -> val p = packets[i % packets.size]; filter.process(p, p.size) }
        out.append("DNS packet → decision (+NXDOMAIN reply for blocks), in-process: %.2f µs/query\n".format(perPacket / 1000))
        out.append("(forwarding allowed queries adds the network resolver's round trip, not measured here)\n")

        // --- Custom keywords: 500 entries. ---
        val kw = CustomKeywords(InMemoryCustomKeywordStore(), max = 500)
        for (i in 0 until 500) kw.add("keyword$i phrase", Category.CUSTOM)
        val queries = listOf("weather tomorrow in riyadh", "keyword499 phrase please", "a much longer search query with many different words in it")
            .map(SearchNormalizer::normalize)
        val kwNs = timeNs(100_000) { i -> kw.match(queries[i % queries.size]) }
        out.append("custom keyword match (500 keywords): %.2f µs/query\n".format(kwNs / 1000))

        // --- Health evaluation. ---
        val inputs = HealthInputs(
            protectionEnabled = true, vpnState = VpnState.RUNNING, vpnPermission = true, dnsFilterActive = true,
            upstreamAvailable = true, rulesReady = true, blockingRuleCount = 1, searchEnabled = true, aiEnabled = true,
            aiTextModelAvailable = true, protectedAppCount = 3, accessibility = AccessibilityState.ENABLED, databaseOk = true,
        )
        val healthNs = timeNs(200_000) { ProtectionHealthEvaluator.evaluate(inputs) }
        out.append("health evaluation (pure logic, excl. Android lookups): %.2f µs\n".format(healthNs / 1000))

        File("build").mkdirs()
        File("build/phase5-bench.txt").writeText(out.toString())
        assertTrue(out.toString(), perPacket < 1_000_000) // < 1 ms/query even on slow CI
        assertTrue(out.toString(), cold < 1_000_000)
    }
}
