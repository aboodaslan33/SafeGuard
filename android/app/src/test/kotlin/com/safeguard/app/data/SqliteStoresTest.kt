package com.safeguard.app.data

import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Runs the real SQLite schema and queries (Robolectric's native SQLite). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 34], manifest = Config.NONE)
class SqliteStoresTest {
    private lateinit var db: SafeGuardDatabase
    private lateinit var rules: SqliteRuleStore
    private lateinit var events: SqliteBlockEventStore

    @Before
    fun setUp() {
        db = SafeGuardDatabase(RuntimeEnvironment.getApplication())
        rules = SqliteRuleStore(db)
        events = SqliteBlockEventStore(db)
    }

    @After
    fun tearDown() = db.close()

    private fun rule(d: String, c: Category, a: RuleAction = RuleAction.BLOCK, s: RuleSource = RuleSource.BUILT_IN) =
        Rule(d, c, a, source = s, updatedAt = 1)

    @Test
    fun crudAndSuffixLookup() {
        rules.upsertAll(listOf(rule("adult.test", Category.SEXUAL), rule("casino.test", Category.GAMBLING)))
        rules.upsert(rule("adult.test", Category.SAFE, RuleAction.ALLOW, RuleSource.USER))
        assertEquals(3, rules.count())
        assertEquals(1, rules.count(RuleSource.USER))

        val found = rules.findEnabled(listOf("www.adult.test", "adult.test"))
        assertEquals(2, found.size)

        // Upsert replaces the (domain, source) row instead of duplicating it.
        rules.upsert(rule("casino.test", Category.DRUGS))
        assertEquals(Category.DRUGS, rules.get("casino.test", RuleSource.BUILT_IN)!!.category)
        assertEquals(3, rules.count())

        assertTrue(rules.setEnabled("casino.test", RuleSource.BUILT_IN, false))
        assertTrue(rules.findEnabled(listOf("casino.test")).isEmpty())
        assertTrue(rules.delete("adult.test", RuleSource.USER))
        assertFalse(rules.delete("adult.test", RuleSource.USER))
        assertNull(rules.get("adult.test", RuleSource.USER))
    }

    @Test
    fun engineOverSqliteMatchesSubdomainsOnly() {
        rules.upsert(rule("adult.test", Category.SEXUAL))
        val engine = RuleEngine(rules)
        val all = ProtectionPolicy.allCategories()
        assertTrue(engine.evaluate("cdn.www.adult.test", all).isBlocked)
        assertFalse(engine.evaluate("safe-adult.test", all).isBlocked)
    }

    @Test
    fun searchIsLiteralNotAPattern() {
        rules.upsertAll(listOf(rule("abc.test", Category.DRUGS), rule("a_c.test", Category.DRUGS), rule("100.test", Category.DRUGS)))
        assertEquals(listOf("a_c.test"), rules.search("a_c").map { it.domain })
        assertEquals(emptyList<String>(), rules.search("%").map { it.domain })
        // Hostile input is just text: bound parameter, no injection.
        assertEquals(emptyList<String>(), rules.search("'; DROP TABLE rules; --").map { it.domain })
        assertEquals(3, rules.count())
    }

    @Test
    fun listFiltersBySourceAndAction() {
        rules.upsertAll(
            listOf(
                rule("a.test", Category.SEXUAL, s = RuleSource.USER),
                rule("b.test", Category.SAFE, RuleAction.ALLOW, RuleSource.USER),
                rule("c.test", Category.GORE),
            ),
        )
        assertEquals(listOf("b.test"), rules.list(RuleSource.USER, RuleAction.ALLOW).map { it.domain })
        assertEquals(2, rules.list(source = RuleSource.USER).size)
        assertEquals(2, rules.countBlocking())
    }

    @Test
    fun blockEventsCountersAndPrune() {
        (1..6).forEach { events.insert(BlockEvent(it * 1000L, "d$it.test", if (it % 2 == 0) Category.SEXUAL else Category.GAMBLING)) }
        assertEquals(6L, events.lifetimeTotal())
        assertEquals(4, events.countSince(3000))
        assertEquals(mapOf(Category.SEXUAL to 3, Category.GAMBLING to 3), events.countByCategorySince(0))
        assertEquals("d6.test", events.recent(1).single().domain)

        events.prune(before = 2500, maxRows = 3)
        assertEquals(3, events.recent(100).size)
        assertEquals(6L, events.lifetimeTotal())

        events.clear()
        assertEquals(0, events.recent(100).size)
        assertEquals(0L, events.lifetimeTotal())
    }
}
