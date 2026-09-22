package com.safeguard.app.engine

import com.safeguard.app.engine.rules.BuiltInRules
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.DecisionReason
import com.safeguard.app.engine.rules.DomainClassifier
import com.safeguard.app.engine.rules.HostsListParser
import com.safeguard.app.engine.rules.InMemoryRuleStore
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.rules.UnknownDomainPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class RuleEngineTest {
    private lateinit var store: InMemoryRuleStore
    private lateinit var engine: RuleEngine
    private val all = ProtectionPolicy.allCategories()

    private fun rule(domain: String, category: Category, action: RuleAction = RuleAction.BLOCK, source: RuleSource = RuleSource.BUILT_IN) =
        Rule(domain, category, action, source = source)

    @Before
    fun setUp() {
        store = InMemoryRuleStore()
        store.upsertAll(
            listOf(
                rule("adult.test", Category.SEXUAL),
                rule("casino.test", Category.GAMBLING),
                rule("gore.test", Category.GORE),
                rule("docs.adult.test", Category.SAFE, RuleAction.ALLOW),
                rule("example.com", Category.SAFE, RuleAction.ALLOW),
            ),
        )
        engine = RuleEngine(store)
    }

    @Test
    fun blocksEnabledCategory() {
        val d = engine.evaluate("adult.test", all)
        assertTrue(d.isBlocked)
        assertEquals(Category.SEXUAL, d.category)
        assertEquals(DecisionReason.CATEGORY_BLOCKED, d.reason)
    }

    @Test
    fun allowsWhenCategoryDisabled() {
        val policy = all.copy(blockedCategories = all.blockedCategories - Category.SEXUAL)
        val d = engine.evaluate("adult.test", policy)
        assertFalse(d.isBlocked)
        assertEquals(DecisionReason.CATEGORY_DISABLED, d.reason)
        // Other categories are unaffected.
        assertTrue(engine.evaluate("casino.test", policy).isBlocked)
    }

    @Test
    fun protectionOffAllowsEverything() {
        val d = engine.evaluate("adult.test", ProtectionPolicy.DISABLED)
        assertFalse(d.isBlocked)
        assertEquals(DecisionReason.PROTECTION_OFF, d.reason)
    }

    @Test
    fun subdomainsInheritTheRule() {
        assertTrue(engine.evaluate("www.adult.test", all).isBlocked)
        assertTrue(engine.evaluate("a.b.c.adult.test", all).isBlocked)
        assertTrue(engine.evaluate("WWW.ADULT.TEST.", all).isBlocked)
    }

    @Test
    fun noSubstringFalsePositives() {
        listOf("safe-adult.test", "adult.test.example.org", "notadult.test", "adulttest", "casino.testing")
            .forEach { assertFalse(it, engine.evaluate(it, all).isBlocked) }
    }

    @Test
    fun moreSpecificSafeRuleWins() {
        val d = engine.evaluate("docs.adult.test", all)
        assertFalse(d.isBlocked)
        assertEquals(DecisionReason.SAFE_RULE, d.reason)
        assertTrue(engine.evaluate("www.adult.test", all).isBlocked)
    }

    @Test
    fun unknownDomainsAreAllowedByDefault() {
        val d = engine.evaluate("some-random-site.org", all)
        assertFalse(d.isBlocked)
        assertEquals(Category.UNKNOWN, d.category)
        assertEquals(DecisionReason.UNKNOWN_ALLOWED, d.reason)
    }

    @Test
    fun strictModeHookBlocksUnknownWhenEnabled() {
        val strict = all.copy(unknownDomains = UnknownDomainPolicy.BLOCK)
        assertTrue(engine.evaluate("some-random-site.org", strict).isBlocked)
        assertFalse(engine.evaluate("example.com", strict).isBlocked)
    }

    @Test
    fun malformedNamesAreNotBlockedAndDoNotThrow() {
        listOf("", "a..b", "-x.test", "a".repeat(300), "exa mple.test").forEach {
            val d = engine.evaluate(it, all)
            assertFalse(d.isBlocked)
            assertEquals(DecisionReason.INVALID_DOMAIN, d.reason)
        }
    }

    @Test
    fun allowlistOverridesListBlock() {
        store.upsert(rule("adult.test", Category.SEXUAL, RuleAction.ALLOW, RuleSource.USER))
        engine.invalidate()
        val d = engine.evaluate("www.adult.test", all)
        assertFalse(d.isBlocked)
        assertEquals(DecisionReason.ALLOWLISTED, d.reason)
    }

    @Test
    fun allowlistOnSubdomainOnlyAllowsThatSubtree() {
        store.upsert(rule("learn.adult.test", Category.SAFE, RuleAction.ALLOW, RuleSource.USER))
        engine.invalidate()
        assertFalse(engine.evaluate("learn.adult.test", all).isBlocked)
        assertTrue(engine.evaluate("adult.test", all).isBlocked)
    }

    @Test
    fun allowlistOverridesUserBlocklist() {
        store.upsert(rule("mine.test", Category.DRUGS, RuleAction.BLOCK, RuleSource.USER))
        store.upsert(rule("ok.mine.test", Category.SAFE, RuleAction.ALLOW, RuleSource.USER))
        engine.invalidate()
        assertTrue(engine.evaluate("mine.test", all).isBlocked)
        assertFalse(engine.evaluate("ok.mine.test", all).isBlocked)
    }

    @Test
    fun userBlocklistAppliesEvenIfCategoryDisabled() {
        store.upsert(rule("custom.test", Category.SEXUAL, RuleAction.BLOCK, RuleSource.USER))
        engine.invalidate()
        val none = all.copy(blockedCategories = emptySet())
        val d = engine.evaluate("www.custom.test", none)
        assertTrue(d.isBlocked)
        assertEquals(DecisionReason.USER_BLOCKLIST, d.reason)
    }

    @Test
    fun disabledRulesAreIgnored() {
        store.setEnabled("casino.test", RuleSource.BUILT_IN, false)
        engine.invalidate()
        assertFalse(engine.evaluate("casino.test", all).isBlocked)
    }

    @Test
    fun categoryTogglesApplyWithoutCacheInvalidation() {
        assertTrue(engine.evaluate("casino.test", all).isBlocked)
        val noGambling = all.copy(blockedCategories = all.blockedCategories - Category.GAMBLING)
        assertFalse(engine.evaluate("casino.test", noGambling).isBlocked)
    }

    @Test
    fun ruleChangesVisibleAfterInvalidate() {
        assertFalse(engine.evaluate("new.test", all).isBlocked)
        store.upsert(rule("new.test", Category.DRUGS))
        engine.invalidate()
        assertTrue(engine.evaluate("new.test", all).isBlocked)
    }

    @Test
    fun classifierHookIsConsultedForUnknownOnly() {
        val classified = RuleEngine(store, DomainClassifier { if (it.endsWith(".bet")) Category.GAMBLING else Category.UNKNOWN })
        assertTrue(classified.evaluate("lucky.bet", all).isBlocked)
        assertFalse(classified.evaluate("example.com", all).isBlocked)
    }

    @Test
    fun builtInFixturesBehaveAsDocumented() {
        val s = InMemoryRuleStore().apply {
            upsertAll(BuiltInRules.production(0))
            upsertAll(BuiltInRules.testFixtures(0))
        }
        val e = RuleEngine(s)
        assertTrue(e.evaluate("www.example.org", all).isBlocked)
        assertEquals(Category.SEXUAL, e.evaluate("example.org", all).category)
        assertTrue(e.evaluate("example.net", all).isBlocked)
        assertFalse(e.evaluate("example.com", all).isBlocked)
    }

    @Test
    fun hostsListParserAcceptsOnlyValidEntries() {
        val text = """
            # comment
            0.0.0.0 bad.test
            127.0.0.1 www.worse.test   # trailing
            plain.test
            0.0.0.0 localhost
            not a valid line at all
            0.0.0.0 in valid.test
            192.168.0.1
        """.trimIndent().lineSequence()
        val rules = HostsListParser.parse(text, Category.GAMBLING, RuleSource.REMOTE, 3, 0).toList()
        assertEquals(listOf("bad.test", "worse.test", "plain.test"), rules.map { it.domain })
        assertTrue(rules.all { it.category == Category.GAMBLING && it.version == 3 })
    }
}
