package com.safeguard.app.engine

import com.safeguard.app.engine.ai.AdapterContentClassifier
import com.safeguard.app.engine.ai.AiSearchFilterService
import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.ai.MockClassifierAdapter
import com.safeguard.app.engine.apps.AccessibilityState
import com.safeguard.app.engine.health.HealthInputs
import com.safeguard.app.engine.health.IncidentDetector
import com.safeguard.app.engine.health.IncidentKind
import com.safeguard.app.engine.health.IncidentLog
import com.safeguard.app.engine.health.Incident
import com.safeguard.app.engine.health.Layer
import com.safeguard.app.engine.health.LayerState
import com.safeguard.app.engine.health.OverallHealth
import com.safeguard.app.engine.health.ProtectionHealthEvaluator
import com.safeguard.app.engine.health.RecoveryPolicy
import com.safeguard.app.engine.health.UpstreamHealth
import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.logging.InMemoryBlockEventStore
import com.safeguard.app.engine.modes.ProtectionMode
import com.safeguard.app.engine.modes.ProtectionModes
import com.safeguard.app.engine.modes.UserSettings
import com.safeguard.app.engine.pause.TemporaryUnlock
import com.safeguard.app.engine.privacy.QueryHasher
import com.safeguard.app.engine.privacy.SearchEventRecorder
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.DecisionReason
import com.safeguard.app.engine.rules.InMemoryRuleStore
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.rules.UserRuleError
import com.safeguard.app.engine.rules.UserRuleException
import com.safeguard.app.engine.rules.UserRules
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.safesearch.YouTubeMode
import com.safeguard.app.engine.search.CustomKeywords
import com.safeguard.app.engine.search.InMemoryCustomKeywordStore
import com.safeguard.app.engine.search.KeywordError
import com.safeguard.app.engine.search.KeywordException
import com.safeguard.app.engine.search.RuleBasedSearchClassifier
import com.safeguard.app.engine.search.SearchNormalizer
import com.safeguard.app.engine.search.SearchPolicyConfig
import com.safeguard.app.engine.search.SearchQuery
import com.safeguard.app.engine.stats.StatisticsService
import com.safeguard.app.engine.status.VpnState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.TimeZone

class ProtectionModesTest {
    private val user = UserSettings(
        categories = setOf(Category.GAMBLING),
        safeSearch = SafeSearchConfig(false, google = false, youtube = YouTubeMode.OFF),
        ai = AiSettings(enabled = false),
    )

    @Test fun normalIsAFixedProtectivePreset() {
        val e = ProtectionModes.resolve(ProtectionMode.NORMAL, user)
        assertEquals(Category.filterable.toSet(), e.categories)
        assertTrue(e.safeSearch.enabled && e.safeSearch.google && e.safeSearch.bing && e.safeSearch.duckDuckGo)
        assertEquals(YouTubeMode.MODERATE, e.safeSearch.youtube)
        assertEquals(DetectionMode.NORMAL, e.ai.mode)
        assertTrue(e.ai.enabled)
        assertEquals(SearchPolicyConfig.DEFAULT_THRESHOLD, e.lexiconThreshold, 1e-9)
    }

    @Test fun strictIsStricterThanNormalEverywhere() {
        val n = ProtectionModes.resolve(ProtectionMode.NORMAL, user)
        val s = ProtectionModes.resolve(ProtectionMode.STRICT, user)
        assertEquals(YouTubeMode.STRICT, s.safeSearch.youtube)
        assertTrue(s.lexiconThreshold < n.lexiconThreshold)
        for (c in Category.filterable) assertTrue(c.id, s.ai.threshold(c) < n.ai.threshold(c))
        assertEquals(n.categories, s.categories)
    }

    @Test fun customPassesUserSettingsThrough() {
        val e = ProtectionModes.resolve(ProtectionMode.CUSTOM, user)
        assertEquals(setOf(Category.GAMBLING), e.categories)
        assertFalse(e.safeSearch.enabled)
        assertFalse(e.ai.enabled)
    }

    @Test fun customNeverLetsNonFilterableCategoriesThrough() {
        val e = ProtectionModes.resolve(ProtectionMode.CUSTOM, user.copy(categories = setOf(Category.SAFE, Category.CUSTOM, Category.DRUGS)))
        assertEquals(setOf(Category.DRUGS), e.categories)
    }

    @Test fun modeChangesNeedPinExceptTightening() {
        assertFalse(ProtectionModes.changeNeedsPin(ProtectionMode.NORMAL, ProtectionMode.STRICT))
        assertFalse(ProtectionModes.changeNeedsPin(ProtectionMode.STRICT, ProtectionMode.STRICT))
        assertTrue(ProtectionModes.changeNeedsPin(ProtectionMode.STRICT, ProtectionMode.NORMAL))
        assertTrue(ProtectionModes.changeNeedsPin(ProtectionMode.NORMAL, ProtectionMode.CUSTOM))
        assertTrue(ProtectionModes.changeNeedsPin(ProtectionMode.CUSTOM, ProtectionMode.STRICT))
    }

    @Test fun missingModeMeansCustomSoOldSettingsKeepWorking() {
        assertEquals(ProtectionMode.CUSTOM, ProtectionMode.fromId(null))
        assertEquals(ProtectionMode.CUSTOM, ProtectionMode.fromId("garbage"))
        assertEquals(ProtectionMode.STRICT, ProtectionMode.fromId("strict"))
    }
}

class TemporaryUnlockTest {
    private val min = 60_000L

    @Test fun activeForTheChosenDurationThenEnds() {
        val p = TemporaryUnlock.start(10, nowWall = 1_000_000, nowElapsed = 5_000)
        assertTrue(p.isActive(1_000_000, 5_000))
        assertTrue(p.isActive(1_000_000 + 9 * min, 5_000 + 9 * min))
        assertEquals(min, p.remainingMs(1_000_000 + 9 * min, 5_000 + 9 * min))
        assertFalse(p.isActive(1_000_000 + 10 * min, 5_000 + 10 * min))
        assertEquals(0, p.remainingMs(1_000_000 + 10 * min, 5_000 + 10 * min))
    }

    @Test fun settingTheClockBackCannotExtendIt() {
        val p = TemporaryUnlock.start(5, nowWall = 1_000_000, nowElapsed = 5_000)
        // 6 real minutes passed, but the wall clock was moved back 1 hour.
        assertFalse(p.isActive(1_000_000 - 60 * min, 5_000 + 6 * min))
    }

    @Test fun rebootEndsIt() {
        val p = TemporaryUnlock.start(30, nowWall = 1_000_000, nowElapsed = 50_000_000)
        // After a reboot elapsed-realtime restarts near zero.
        assertFalse(p.isActive(1_000_000 + min, 10_000))
    }

    @Test fun onlyFiveTenOrThirtyMinutes() {
        for (bad in listOf(0, 1, 15, 31, 60, -5)) {
            try {
                TemporaryUnlock.start(bad, 0, 0)
                fail("$bad")
            } catch (e: IllegalArgumentException) {
                // expected
            }
        }
        try {
            TemporaryUnlock(0, 0, 31 * min)
            fail()
        } catch (e: IllegalArgumentException) {
            // corrupt stored value can't create a long pause
        }
    }
}

class HealthEvaluatorTest {
    private val healthy = HealthInputs(
        protectionEnabled = true,
        vpnState = VpnState.RUNNING,
        vpnPermission = true,
        dnsFilterActive = true,
        upstreamAvailable = true,
        rulesReady = true,
        blockingRuleCount = 100,
        searchEnabled = true,
        aiEnabled = true,
        aiTextModelAvailable = true,
        protectedAppCount = 0,
        accessibility = AccessibilityState.DISABLED,
        databaseOk = true,
    )

    private fun eval(i: HealthInputs) = ProtectionHealthEvaluator.evaluate(i)

    @Test fun everythingWorkingIsProtected() {
        val r = eval(healthy)
        assertEquals(OverallHealth.PROTECTED, r.overall)
        assertEquals(LayerState.ACTIVE, r.layer(Layer.VPN).state)
        assertEquals(LayerState.NOT_CONFIGURED, r.layer(Layer.APPS).state)
        assertEquals(8, r.layers.size)
    }

    @Test fun coreFailuresAreNotProtected() {
        for ((inputs, reason) in listOf(
            healthy.copy(protectionEnabled = false) to "protection_off",
            healthy.copy(paused = true) to "paused",
            healthy.copy(safeMode = true) to "safe_mode",
            healthy.copy(vpnState = VpnState.ERROR, dnsFilterActive = false) to "vpn_error",
            healthy.copy(vpnState = VpnState.REVOKED, dnsFilterActive = false, otherVpnActive = true) to "other_vpn_or_revoked",
            healthy.copy(vpnState = VpnState.PERMISSION_REQUIRED, vpnPermission = false, dnsFilterActive = false) to "permission_required",
            healthy.copy(dnsFilterActive = false) to "filter_stopped",
        )) {
            val r = eval(inputs)
            assertEquals(reason, OverallHealth.NOT_PROTECTED, r.overall)
            assertEquals(reason, r.reason)
        }
    }

    @Test fun weakenedLayersArePartial() {
        for ((inputs, layer) in listOf(
            healthy.copy(privateDnsStrict = true) to Layer.DNS,
            healthy.copy(upstreamFailing = true) to Layer.DNS,
            healthy.copy(blockingRuleCount = 0) to Layer.RULES,
            healthy.copy(aiTextModelAvailable = false) to Layer.AI,
            healthy.copy(protectedAppCount = 3, accessibility = AccessibilityState.DISABLED) to Layer.APPS,
            healthy.copy(databaseOk = false) to Layer.DATABASE,
        )) {
            val r = eval(inputs)
            assertEquals(layer.id, OverallHealth.PARTIALLY_PROTECTED, r.overall)
            assertTrue(r.reason!!, r.reason!!.startsWith(layer.id))
        }
    }

    @Test fun layersTheUserTurnedOffDontLowerTheVerdict() {
        val r = eval(healthy.copy(searchEnabled = false, aiEnabled = false))
        assertEquals(OverallHealth.PROTECTED, r.overall)
        assertEquals(LayerState.OFF, r.layer(Layer.SEARCH).state)
        assertEquals(LayerState.OFF, r.layer(Layer.AI).state)
    }

    @Test fun offlineIsStillProtected() {
        val r = eval(healthy.copy(upstreamAvailable = false))
        assertEquals(OverallHealth.PROTECTED, r.overall)
        assertEquals("offline", r.layer(Layer.DNS).reason)
    }

    @Test fun protectedAppsWithAccessibilityOnAreActive() {
        val r = eval(healthy.copy(protectedAppCount = 2, accessibility = AccessibilityState.ENABLED))
        assertEquals(LayerState.ACTIVE, r.layer(Layer.APPS).state)
        assertEquals(OverallHealth.PROTECTED, r.overall)
    }
}

class RecoveryTest {
    private val facts = RecoveryPolicy.Facts(
        userWantsProtection = true,
        paused = false,
        safeMode = false,
        vpnState = VpnState.ERROR,
        vpnPermission = true,
        otherVpnActive = false,
    )

    @Test fun recoversOnlyWhatSafeGuardMayRestart() {
        val p = RecoveryPolicy()
        assertTrue(p.isRecoverable(facts))
        assertTrue(p.isRecoverable(facts.copy(vpnState = VpnState.STOPPED)))
        for (never in listOf(
            facts.copy(userWantsProtection = false),
            facts.copy(paused = true),
            facts.copy(safeMode = true),
            facts.copy(vpnPermission = false),
            facts.copy(otherVpnActive = true),
            facts.copy(vpnState = VpnState.REVOKED), // never fight another VPN / the user
            facts.copy(vpnState = VpnState.PERMISSION_REQUIRED),
            facts.copy(vpnState = VpnState.RUNNING),
        )) {
            assertFalse(never.toString(), p.isRecoverable(never))
            assertNull(p.nextDelay(never, 0))
        }
    }

    @Test fun backoffIsBoundedAndWindowed() {
        val p = RecoveryPolicy(maxAttempts = 3, windowMs = 600_000)
        assertEquals(1_000L, p.nextDelay(facts, 0))
        p.recordAttempt(0)
        assertEquals(4_000L, p.nextDelay(facts, 1))
        p.recordAttempt(1)
        assertEquals(16_000L, p.nextDelay(facts, 2))
        p.recordAttempt(2)
        assertNull(p.nextDelay(facts, 3))
        assertEquals(4_000L, p.nextDelay(facts, 600_001)) // oldest two expired, one left
        assertEquals(1_000L, p.nextDelay(facts, 600_002)) // whole window passed
        p.reset()
        assertEquals(1_000L, p.nextDelay(facts, 3))
    }

    @Test fun upstreamFailingNeedsRepeatedFailuresOverTime() {
        val u = UpstreamHealth(threshold = 3, windowMs = 30_000)
        repeat(3) { u.failure(1_000L + it) }
        assertFalse(u.isFailing(10_000))
        assertTrue(u.isFailing(31_001))
        u.success(31_002)
        assertFalse(u.isFailing(90_000))
    }
}

class IncidentTest {
    @Test fun unrequestedStopsAreIncidents() {
        assertEquals(IncidentKind.VPN_REVOKED, IncidentDetector.onVpnTransition(VpnState.RUNNING, VpnState.REVOKED, true, 1)?.kind)
        assertEquals(IncidentKind.VPN_FAILED, IncidentDetector.onVpnTransition(VpnState.RUNNING, VpnState.ERROR, true, 1)?.kind)
        assertEquals(IncidentKind.PERMISSION_REVOKED, IncidentDetector.onVpnTransition(VpnState.STARTING, VpnState.PERMISSION_REQUIRED, true, 1)?.kind)
    }

    @Test fun userActionsAreNotIncidents() {
        assertNull(IncidentDetector.onVpnTransition(VpnState.RUNNING, VpnState.STOPPED, true, 1))
        assertNull(IncidentDetector.onVpnTransition(VpnState.RUNNING, VpnState.REVOKED, false, 1))
        assertNull(IncidentDetector.onVpnTransition(VpnState.RUNNING, VpnState.RUNNING, true, 1))
        assertNull(IncidentDetector.onVpnTransition(VpnState.STOPPED, VpnState.REVOKED, true, 1))
    }

    @Test fun accessibilityOffWithProtectedAppsIsAnIncident() {
        assertNotNull(IncidentDetector.onAccessibilityChange(true, false, 2, 1))
        assertNull(IncidentDetector.onAccessibilityChange(true, false, 0, 1))
        assertNull(IncidentDetector.onAccessibilityChange(false, false, 2, 1))
    }

    @Test fun logIsBoundedAndAcknowledgeable() {
        val log = IncidentLog(max = 3)
        (1..5).forEach { log.add(Incident(it.toLong(), IncidentKind.VPN_FAILED)) }
        assertEquals(listOf(3L, 4L, 5L), log.all().map { it.timestamp })
        log.add(Incident(6, IncidentKind.RECOVERED))
        assertEquals(2, log.unacknowledged().size) // RECOVERED is informational
        log.acknowledge(5)
        assertTrue(log.unacknowledged().isEmpty())
    }
}

class UserRulesTest {
    private val store = InMemoryRuleStore()
    private val rules = UserRules(store, clock = { 7 }, maxRules = 5)
    private val engine = RuleEngine(store)
    private val policy = ProtectionPolicy.allCategories()

    private fun expect(error: UserRuleError, block: () -> Unit) {
        try {
            block()
            fail("expected $error")
        } catch (e: UserRuleException) {
            assertEquals(error, e.error)
        }
    }

    @Test fun domainsAreNormalised() {
        assertEquals("example.com", rules.add("HTTPS://WWW.Example.COM/path?q=1", RuleAction.BLOCK, Category.CUSTOM).domain)
        assertEquals("xn--mgbh0fb.xn--kgbechtv", rules.add("مثال.إختبار", RuleAction.BLOCK, Category.CUSTOM).domain)
    }

    @Test fun invalidAndMaliciousInputIsRejected() {
        for (bad in listOf(
            "", "   ", "com", "localhost", "192.168.1.1", "[::1]", "exa mple.com", "-bad.com",
            "a".repeat(64) + ".com", "x.".repeat(200) + "com", "'; DROP TABLE rules; --",
            "<script>alert(1)</script>.com", "example..com", "example.123",
        )) {
            expect(UserRuleError.INVALID_DOMAIN) { rules.add(bad, RuleAction.BLOCK, Category.CUSTOM) }
        }
        assertEquals(0, store.count())
    }

    @Test fun duplicatesAndConflictsAreReportedNotReplaced() {
        rules.add("example.com", RuleAction.BLOCK, Category.CUSTOM)
        expect(UserRuleError.DUPLICATE_DOMAIN) { rules.add("www.EXAMPLE.com", RuleAction.BLOCK, Category.GAMBLING) }
        expect(UserRuleError.IN_OTHER_LIST) { rules.add("example.com", RuleAction.ALLOW, Category.SAFE) }
        assertEquals(Category.CUSTOM, store.get("example.com", RuleSource.USER)!!.category)
    }

    @Test fun categoriesMustBeAssignable() {
        expect(UserRuleError.INVALID_CATEGORY) { rules.add("a.com", RuleAction.BLOCK, Category.SAFE) }
        expect(UserRuleError.INVALID_CATEGORY) { rules.add("a.com", RuleAction.BLOCK, Category.UNKNOWN) }
        rules.add("a.com", RuleAction.BLOCK, Category.DRUGS)
    }

    @Test fun listSizeIsBounded() {
        (1..5).forEach { rules.add("d$it.com", RuleAction.BLOCK, Category.CUSTOM) }
        expect(UserRuleError.LIMIT_REACHED) { rules.add("d6.com", RuleAction.BLOCK, Category.CUSTOM) }
    }

    @Test fun customBlocksCoverSubdomainsWhateverTheToggles() {
        rules.add("example.com", RuleAction.BLOCK, Category.CUSTOM)
        val none = ProtectionPolicy(true, emptySet())
        for (d in listOf("example.com", "www.example.com", "a.b.example.com")) {
            val decision = engine.evaluate(d, none)
            assertEquals(d, RuleAction.BLOCK, decision.action)
            assertEquals(Category.CUSTOM, decision.category)
        }
        assertEquals(RuleAction.ALLOW, engine.evaluate("notexample.com", none).action)
        assertEquals(RuleAction.ALLOW, engine.evaluate("example.com.evil.net", none).action)
    }

    @Test fun exactAllowlistEntryDoesNotOpenSubdomains() {
        store.upsert(com.safeguard.app.engine.rules.Rule("site.test", Category.GAMBLING, RuleAction.BLOCK, source = RuleSource.BUILT_IN))
        rules.add("site.test", RuleAction.ALLOW, Category.SAFE, includeSubdomains = false)
        engine.invalidate()
        assertEquals(DecisionReason.ALLOWLISTED, engine.evaluate("site.test", policy).reason)
        assertEquals(DecisionReason.ALLOWLISTED, engine.evaluate("www.site.test", policy).reason)
        assertEquals(RuleAction.BLOCK, engine.evaluate("casino.site.test", policy).action)
    }

    @Test fun allowlistWithSubdomainsCoversThemExplicitly() {
        store.upsert(com.safeguard.app.engine.rules.Rule("site.test", Category.GAMBLING, RuleAction.BLOCK, source = RuleSource.BUILT_IN))
        rules.add("site.test", RuleAction.ALLOW, Category.SAFE, includeSubdomains = true)
        assertEquals(RuleAction.ALLOW, engine.evaluate("casino.site.test", policy).action)
        assertEquals(RuleAction.ALLOW, engine.evaluate("safe-site.test", policy).action) // not a subdomain, no rule
    }

    @Test fun blockEntriesAlwaysCoverSubdomains() {
        val r = rules.add("x.com", RuleAction.BLOCK, Category.CUSTOM, includeSubdomains = false)
        assertTrue(r.includeSubdomains)
    }

    @Test fun removal() {
        rules.add("example.com", RuleAction.BLOCK, Category.CUSTOM)
        assertFalse(rules.remove("example.com", RuleAction.ALLOW))
        assertTrue(rules.remove("https://www.example.com/", RuleAction.BLOCK))
        assertFalse(rules.remove("example.com", RuleAction.BLOCK))
        assertFalse(rules.remove("not a domain", RuleAction.BLOCK))
    }
}

class CustomKeywordsTest {
    private val keywords = CustomKeywords(InMemoryCustomKeywordStore(), clock = { 1 }, max = 3)
    private fun match(q: String) = keywords.match(SearchNormalizer.normalize(q))

    private fun expect(error: KeywordError, block: () -> Unit) {
        try {
            block()
            fail("expected $error")
        } catch (e: KeywordException) {
            assertEquals(error, e.error)
        }
    }

    @Test fun validation() {
        expect(KeywordError.KEYWORD_TOO_SHORT) { keywords.add("ab", Category.CUSTOM) }
        expect(KeywordError.INVALID_KEYWORD) { keywords.add("   ", Category.CUSTOM) }
        expect(KeywordError.INVALID_KEYWORD) { keywords.add("12345", Category.CUSTOM) }
        expect(KeywordError.INVALID_KEYWORD) { keywords.add("one two three four five six", Category.CUSTOM) }
        expect(KeywordError.INVALID_KEYWORD) { keywords.add("x".repeat(300), Category.CUSTOM) }
        expect(KeywordError.INVALID_CATEGORY) { keywords.add("valid", Category.SAFE) }
    }

    @Test fun normalisedDuplicatesAndLimit() {
        val k = keywords.add("  Crypto-CASINO!! ", Category.GAMBLING)
        assertEquals("crypto casino", k.phrase)
        expect(KeywordError.DUPLICATE_KEYWORD) { keywords.add("crypto casino", Category.GAMBLING) }
        keywords.add("second", Category.CUSTOM)
        keywords.add("third", Category.CUSTOM)
        expect(KeywordError.LIMIT_REACHED) { keywords.add("fourth", Category.CUSTOM) }
    }

    @Test fun wholeWordsOnlyNeverSubstrings() {
        keywords.add("ass", Category.CUSTOM)
        assertNull(match("physics class notes"))
        assertNull(match("passport renewal"))
        assertNull(match("assessment"))
        assertNotNull(match("the ass video"))
    }

    @Test fun phrasesMatchInOrderAndArabicPrefixes() {
        keywords.add("dark market", Category.DRUGS)
        keywords.add("قمار", Category.GAMBLING)
        assertNotNull(match("best DARK market links"))
        assertNull(match("market is dark"))
        assertNotNull(match("مواقع القمار"))
    }

    @Test fun removingAKeywordStopsMatching() {
        val k = keywords.add("forbidden", Category.CUSTOM)
        assertNotNull(match("forbidden word"))
        assertTrue(keywords.remove(k.id))
        assertNull(match("forbidden word"))
    }
}

/** Keywords + lexicon + AI in one pipeline. */
class SearchPipelineTest {
    private val store = InMemoryBlockEventStore()
    private val logger = BlockLogger(store, { it.run() }, clock = { 1_000L })
    private val keywords = CustomKeywords(InMemoryCustomKeywordStore())
    private val mock = MockClassifierAdapter()
    private var cfg = SearchPolicyConfig(true, Category.filterable.toSet())

    private val service = AiSearchFilterService(
        rules = RuleBasedSearchClassifier(),
        config = { cfg },
        ai = AdapterContentClassifier(listOf(mock)),
        aiSettings = { AiSettings() },
        listener = SearchEventRecorder(logger, QueryHasher(ByteArray(32))),
        keywords = keywords,
    )

    @Test fun keywordBlocksFirstAndApplyEvenIfCategoryDisabled() {
        keywords.add("glitterbomb", Category.CUSTOM)
        cfg = SearchPolicyConfig(true, emptySet())
        val d = service.classify(SearchQuery("google", "where to buy glitterbomb"))
        assertEquals(RuleAction.BLOCK, d.action)
        assertEquals(AiSearchFilterService.RULE_TYPE_CUSTOM_KEYWORD, d.ruleType)
        assertEquals(0, mock.calls)
        val e = store.recent(1).single()
        assertEquals(EventSource.SEARCH, e.source)
        assertFalse(e.subject.contains("glitterbomb"))
    }

    @Test fun keywordsDoNothingWhenSearchProtectionIsOff() {
        keywords.add("glitterbomb", Category.CUSTOM)
        cfg = SearchPolicyConfig.DISABLED
        assertEquals(RuleAction.ALLOW, service.classify(SearchQuery("google", "glitterbomb")).action)
    }

    @Test fun withoutAKeywordTheLexiconAndAiStillRun() {
        keywords.add("glitterbomb", Category.CUSTOM)
        assertEquals("keyword", service.classify(SearchQuery("google", "online casino")).ruleType)
        mock.scores = mapOf(Category.VIOLENCE to 0.97)
        assertEquals(AiSearchFilterService.RULE_TYPE_AI_TEXT, service.classify(SearchQuery("google", "unseen words")).ruleType)
    }

    @Test fun strictLexiconThresholdCatchesWeakerMatches() {
        val weak = com.safeguard.app.engine.search.SearchClassification(mapOf(Category.GAMBLING to 0.5), listOf("ga99"), "keyword")
        val normal = SearchPolicyConfig(true, Category.filterable.toSet(), defaultThreshold = ProtectionModes.NORMAL_LEXICON_THRESHOLD)
        val strict = normal.copy(defaultThreshold = ProtectionModes.STRICT_LEXICON_THRESHOLD)
        assertEquals(RuleAction.ALLOW, com.safeguard.app.engine.search.SearchPolicy.decide(weak, normal).action)
        assertEquals(RuleAction.BLOCK, com.safeguard.app.engine.search.SearchPolicy.decide(weak, strict).action)
    }
}

class DetailedStatisticsTest {
    @Test fun countsOnlyBlocksPerSourceAndWindow() {
        val day = 24L * 60 * 60 * 1000
        val now = 100 * day + 12 * 60 * 60 * 1000 // noon UTC
        val store = InMemoryBlockEventStore()
        fun add(at: Long, source: EventSource, c: Category, action: RuleAction = RuleAction.BLOCK) =
            store.insert(BlockEvent(at, "s", c, source, action))
        add(now - 1_000, EventSource.DNS, Category.SEXUAL)
        add(now - 2_000, EventSource.SEARCH, Category.GAMBLING)
        add(now - 3_000, EventSource.AI, Category.VIOLENCE)
        add(now - 4_000, EventSource.MANUAL, Category.UNKNOWN, RuleAction.ALLOW) // temporary unlock: not a block
        add(now - 3 * day, EventSource.DNS, Category.SEXUAL)
        add(now - 20 * day, EventSource.AI, Category.DRUGS)

        val stats = StatisticsService(store, clock = { now }, zone = { TimeZone.getTimeZone("UTC") }, reportsSince = { since -> if (since <= now - 7 * day) 2 else 1 })
            .detailed()
        assertEquals(3, stats.today.total)
        assertEquals(mapOf(EventSource.DNS to 1, EventSource.SEARCH to 1, EventSource.AI to 1), stats.today.bySource)
        assertEquals(4, stats.last7Days.total)
        assertEquals(5, stats.last30Days.total)
        assertEquals(2, stats.last30Days.bySource[EventSource.AI])
        assertEquals(2, stats.last30Days.byCategory[Category.SEXUAL])
        assertEquals(1, stats.today.falsePositiveReports)
        assertEquals(2, stats.last30Days.falsePositiveReports)
        assertEquals(5L, store.lifetimeTotal()) // the ALLOW event isn't counted
    }
}
