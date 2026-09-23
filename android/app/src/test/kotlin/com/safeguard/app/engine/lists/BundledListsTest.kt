package com.safeguard.app.engine.lists

import com.safeguard.app.engine.rules.BundledListStore
import com.safeguard.app.engine.rules.BundledLists
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.CompositeRuleStore
import com.safeguard.app.engine.rules.DecisionReason
import com.safeguard.app.engine.rules.HashedDomainList
import com.safeguard.app.engine.rules.InMemoryRuleStore
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.rules.UserRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer

class BundledListsTest {
    private fun list(category: Category, vararg domains: String) =
        HashedDomainList.parse(ByteBuffer.wrap(HashedDomainList.build(category, domains.toList())))

    @Test fun entriesCoverThemselvesAndSubdomainsOnly() {
        val l = list(Category.GAMBLING, "casino.test", "blog.host.test")
        assertTrue(l.contains("casino.test"))
        assertFalse(l.contains("host.test")) // parent of an entry
        assertFalse(l.contains("other.host.test")) // sibling
        val engine = RuleEngine(CompositeRuleStore(InMemoryRuleStore(), BundledListStore { listOf(l) }))
        val policy = ProtectionPolicy.allCategories()
        assertEquals(RuleAction.BLOCK, engine.evaluate("www.casino.test", policy).action)
        assertEquals(RuleAction.BLOCK, engine.evaluate("a.blog.host.test", policy).action)
        assertEquals(RuleAction.ALLOW, engine.evaluate("host.test", policy).action)
        assertEquals(RuleAction.ALLOW, engine.evaluate("mycasino.test", policy).action)
        assertEquals(Category.GAMBLING, engine.evaluate("casino.test", policy).category)
    }

    @Test fun usualPrecedenceApplies() {
        val store = InMemoryRuleStore()
        val engine = RuleEngine(CompositeRuleStore(store, BundledListStore { listOf(list(Category.GAMBLING, "casino.test")) }))
        // Category off → allowed.
        assertEquals(DecisionReason.CATEGORY_DISABLED, engine.evaluate("casino.test", ProtectionPolicy(true, setOf(Category.SEXUAL))).reason)
        // User allowlist wins over the list.
        UserRules(store).add("casino.test", RuleAction.ALLOW, Category.SAFE)
        engine.invalidate()
        assertEquals(DecisionReason.ALLOWLISTED, engine.evaluate("casino.test", ProtectionPolicy.allCategories()).reason)
        // Protection off → allowed.
        assertEquals(RuleAction.ALLOW, engine.evaluate("casino.test", ProtectionPolicy.DISABLED).action)
    }

    @Test fun corePlatformsCanNeverBeBlockedByAList() {
        val bad = list(Category.SEXUAL, "instagram.com", "tumblr.com", "some-blog.tumblr.com")
        val engine = RuleEngine(CompositeRuleStore(InMemoryRuleStore(), BundledListStore { listOf(bad) }))
        val policy = ProtectionPolicy.allCategories()
        assertEquals(RuleAction.ALLOW, engine.evaluate("instagram.com", policy).action)
        assertEquals(RuleAction.ALLOW, engine.evaluate("www.tumblr.com", policy).action)
        assertEquals(RuleAction.BLOCK, engine.evaluate("some-blog.tumblr.com", policy).action)
    }

    @Test fun malformedListsAreRejected() {
        val good = HashedDomainList.build(Category.DRUGS, listOf("a.test", "b.test"))
        fun rejects(b: ByteArray) = try { HashedDomainList.parse(ByteBuffer.wrap(b)); false } catch (e: IllegalArgumentException) { true }
        assertTrue(rejects(ByteArray(0)))
        assertTrue(rejects(good.copyOf(good.size - 1)))
        assertTrue(rejects(good + ByteArray(8)))
        assertTrue(rejects(good.copyOf().also { it[0] = 'X'.code.toByte() }))
        // Unsorted hashes.
        val swapped = good.copyOf()
        val start = good.size - 16
        for (i in 0 until 8) { val t = swapped[start + i]; swapped[start + i] = swapped[start + 8 + i]; swapped[start + 8 + i] = t }
        assertTrue(rejects(swapped))
        // A non-filterable category can't be a list.
        try {
            HashedDomainList.parse(ByteBuffer.wrap(HashedDomainList.build(Category.SAFE, listOf("a.test"))))
            fail()
        } catch (e: IllegalArgumentException) {
            // expected
        }
    }

    @Test fun shippedListsBlockRealEntriesFast() {
        val lists = BundledLists.specs.map { ListFiles.load(it.assetPath) }
        val engine = RuleEngine(CompositeRuleStore(InMemoryRuleStore(), BundledListStore { lists }), cacheSize = 16)
        val policy = ProtectionPolicy.allCategories()
        val samples = ListFiles.samples()
        for ((category, domains) in samples) {
            for (d in domains) {
                val decision = engine.evaluate("www.$d", policy)
                assertEquals(d, RuleAction.BLOCK, decision.action)
                assertEquals(d, category, decision.category.id)
                assertEquals(RuleSource.BUNDLED_LIST, decision.matchedRule!!.source)
            }
        }
        // Cold lookups (tiny cache), 5 labels each → 4 suffixes × 3 lists.
        val n = 50_000
        repeat(5_000) { engine.evaluate("x$it.cdn.example$it.com", policy) }
        val t0 = System.nanoTime()
        for (i in 0 until n) engine.evaluate("a$i.b.site$i.example.org", policy)
        val us = (System.nanoTime() - t0) / 1000.0 / n
        File("build").mkdirs()
        File("build/lists-bench.txt").writeText(
            "bundled lists: ${lists.sumOf { it.size }} entries; cold lookup (4 suffixes x 3 lists, cache miss) %.2f µs (JVM, not a phone)\n".format(us),
        )
        assertTrue("$us µs", us < 500)
    }
}
