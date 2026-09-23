package com.safeguard.app.engine

import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockEventStore
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.InMemoryBlockEventStore
import com.safeguard.app.engine.rules.BundledListStore
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.CompositeRuleStore
import com.safeguard.app.engine.rules.HashedDomainList
import com.safeguard.app.engine.rules.InMemoryRuleStore
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.rules.RuleStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/** Phase 7: components fail safely instead of crashing the process or VPN. */
class Phase7Test {
    private val policy = ProtectionPolicy.allCategories()

    /** A store whose database "breaks" on demand (disk error, corruption). */
    private class FlakyStore(private val inner: RuleStore = InMemoryRuleStore()) : RuleStore by inner {
        @Volatile var broken = false
        override fun findEnabled(domains: Collection<String>): List<Rule> {
            if (broken) throw IllegalStateException("database disk image is malformed")
            return inner.findEnabled(domains)
        }
    }

    private fun gamblingList(vararg domains: String) =
        HashedDomainList.parse(ByteBuffer.wrap(HashedDomainList.build(Category.GAMBLING, domains.toList())))

    @Test fun databaseErrorKeepsBundledListsBlocking() {
        val db = FlakyStore().apply { upsert(Rule("mine.test", Category.CUSTOM, RuleAction.BLOCK, source = RuleSource.USER)) }
        val lists = listOf(gamblingList("casino.test"))
        var failures = 0
        val engine = RuleEngine(CompositeRuleStore(db, BundledListStore { lists }) { failures++ })

        db.broken = true
        // No exception reaches the DNS thread; the bundled list still blocks.
        assertEquals(RuleAction.BLOCK, engine.evaluate("www.casino.test", policy).action)
        assertEquals(RuleAction.ALLOW, engine.evaluate("mine.test", policy).action) // user rules unavailable
        assertTrue(failures >= 2)

        // Degraded answers weren't cached: once the database is back, user
        // rules apply immediately.
        db.broken = false
        assertEquals(RuleAction.BLOCK, engine.evaluate("mine.test", policy).action)
    }

    @Test fun lookupRacingAnInvalidateIsNotCached() {
        var lists = emptyList<HashedDomainList>()
        lateinit var engine: RuleEngine
        val store = object : RuleStore by InMemoryRuleStore() {
            override fun findEnabled(domains: Collection<String>): List<Rule> {
                val snapshot = BundledListStore { lists }.find(domains)
                // The lists finish loading while this lookup is in flight.
                lists = listOf(gamblingList("casino.test"))
                engine.invalidate()
                return snapshot
            }
        }
        engine = RuleEngine(store)
        assertEquals(RuleAction.ALLOW, engine.evaluate("casino.test", policy).action)
        // A stale "allow" would have stayed cached; now the lists apply.
        assertEquals(RuleAction.BLOCK, engine.evaluate("casino.test", policy).action)
    }

    @Test fun logWriteFailureDoesNotThrow() {
        val failing = object : BlockEventStore by InMemoryBlockEventStore() {
            override fun insert(event: BlockEvent) = throw IllegalStateException("disk full")
            override fun prune(before: Long, maxRows: Int) = throw IllegalStateException("disk full")
        }
        val logger = BlockLogger(failing, { it.run() }, clock = { 1_000L })
        logger.record(BlockEvent(1_000L, "casino.test", Category.GAMBLING))
        logger.applyRetention()
        assertEquals(2L, logger.failedWrites)
    }
}
