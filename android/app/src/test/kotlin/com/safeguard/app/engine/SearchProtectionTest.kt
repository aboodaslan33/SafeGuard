package com.safeguard.app.engine

import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.logging.InMemoryBlockEventStore
import com.safeguard.app.engine.privacy.QueryHasher
import com.safeguard.app.engine.privacy.SearchEventRecorder
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.search.CombinedSearchClassifier
import com.safeguard.app.engine.search.LexiconEntry
import com.safeguard.app.engine.search.RuleBasedSearchClassifier
import com.safeguard.app.engine.search.RuleBasedSearchFilterService
import com.safeguard.app.engine.search.SearchClassification
import com.safeguard.app.engine.search.SearchClassifier
import com.safeguard.app.engine.search.SearchNormalizer
import com.safeguard.app.engine.search.SearchPolicy
import com.safeguard.app.engine.search.SearchPolicyConfig
import com.safeguard.app.engine.search.SearchQuery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SearchNormalizerTest {
    private fun n(s: String) = SearchNormalizer.normalize(s).text

    @Test fun english() = assertEquals("online casino", n("  Online   CASINO "))

    @Test fun arabicDiacriticsTatweelAndLetterVariants() {
        assertEquals("اباحيه", n("إِبَاحِيَّة"))
        assertEquals("قمار", n("قـــمـــار"))
        assertEquals("مستشفي", n("مستشفى"))
        assertEquals("مسوول", n("مسؤول"))
        assertEquals("ا ا ا ا", n("أ إ آ ٱ"))
    }

    @Test fun mixedLanguage() = assertEquals("كازينو casino 2024", n("كازينو-Casino ٢٠٢٤"))

    @Test fun whitespaceAndPunctuation() {
        assertEquals("sex video", n("sex!!!...video\t\n"))
        assertEquals("", n("   ...,;!? "))
        assertTrue(SearchNormalizer.normalize("").isEmpty)
    }

    @Test fun unicodeCompatibilityAndLatinDiacritics() {
        assertEquals("porn", n("ｐｏｒｎ")) // full-width
        assertEquals("porn", n("pórñ"))
        assertEquals("cafe", n("café"))
    }

    @Test fun repeatedCharacterVariants() {
        assertTrue("porn" in SearchNormalizer.variants("poooorn"))
        assertTrue("xxx" in SearchNormalizer.variants("xxx"))
        assertEquals("aa", SearchNormalizer.squeeze("aaaa", 2))
    }

    @Test fun arabicPrefixVariants() {
        assertTrue("قمار" in SearchNormalizer.variants("والقمار"))
        assertTrue("قمار" in SearchNormalizer.variants("بالقمار"))
        // Short words keep their letters (no "ال" stripping to 1-2 letters).
        assertEquals(setOf("الم"), SearchNormalizer.variants("الم"))
    }

    @Test fun inputIsCapped() {
        val q = SearchNormalizer.normalize("a ".repeat(10_000))
        assertTrue(q.tokens.size <= 64)
    }
}

class SearchClassifierTest {
    private val classifier = RuleBasedSearchClassifier()
    private val all = SearchPolicyConfig(true, Category.filterable.toSet())

    private fun decide(q: String, config: SearchPolicyConfig = all) =
        SearchPolicy.decide(classifier.classify(SearchNormalizer.normalize(q)), config)

    @Test fun everyCategoryIsDetectedInEnglishAndArabic() {
        val cases = mapOf(
            Category.SEXUAL to listOf("free porn", "افلام إباحية"),
            Category.VIOLENCE to listOf("beheading clip", "مقطع إعدام"),
            Category.GORE to listOf("gore pics", "أشلاء"),
            Category.GAMBLING to listOf("online casino bonus", "مواقع مراهنات"),
            Category.DRUGS to listOf("buy cocaine", "شراء مخدرات"),
            Category.DANGEROUS to listOf("how to make a bomb", "طريقة صنع قنبلة"),
        )
        for ((category, queries) in cases) for (q in queries) {
            val d = decide(q)
            assertEquals(q, RuleAction.BLOCK, d.action)
            assertEquals(q, category, d.category)
            assertTrue(q, d.confidence >= 0.6)
            assertEquals("keyword", d.ruleType)
        }
    }

    @Test fun safeAndUnknownQueriesAreAllowed() {
        for (q in listOf("weather riyadh", "طقس الرياض", "flutter tutorial", "وصفة كبسة", "")) {
            val d = decide(q)
            assertEquals(q, RuleAction.ALLOW, d.action)
            assertEquals(q, Category.UNKNOWN, d.category)
        }
    }

    @Test fun noSubstringFalsePositives() {
        for (q in listOf("essex county", "sussex university", "casinos history book", "gorey ireland", "methodology", "sexton poet")) {
            assertEquals(q, RuleAction.ALLOW, decide(q).action)
        }
    }

    @Test fun protectiveContextDampensScores() {
        for (q in listOf("sex education for parents", "drug addiction help", "علاج إدمان المخدرات", "casino history")) {
            assertEquals(q, RuleAction.ALLOW, decide(q).action)
        }
    }

    @Test fun ambiguousWeakTermsStayBelowThreshold() {
        val d = decide("sex")
        assertEquals(RuleAction.ALLOW, d.action)
        assertEquals(Category.SEXUAL, d.category)
        assertEquals("below_threshold", d.reason)
    }

    @Test fun mixedCategoryQueryPicksStrongestEnabled() {
        val d = decide("casino porn")
        assertEquals(RuleAction.BLOCK, d.action)
        assertEquals(Category.SEXUAL, d.category) // 1.0 > 0.9
        val noSexual = all.copy(blockedCategories = all.blockedCategories - Category.SEXUAL)
        assertEquals(Category.GAMBLING, decide("casino porn", noSexual).category)
    }

    @Test fun obfuscatedSpellingStillMatches() {
        assertEquals(RuleAction.BLOCK, decide("POOORN!!!").action)
        assertEquals(RuleAction.BLOCK, decide("والقمار").action)
    }

    @Test fun ruleIdsAreReportedNotText() {
        val c = classifier.classify(SearchNormalizer.normalize("online casino"))
        assertTrue(c.matchedRuleIds.containsAll(listOf("ga01", "ga02")))
        assertTrue(c.matchedRuleIds.none { it.contains("casino") })
    }

    @Test fun combinedClassifierTakesMaxPerCategory() {
        val fakeAi = SearchClassifier { SearchClassification(mapOf(Category.GORE to 0.95), listOf("ai"), "ai") }
        val combined = CombinedSearchClassifier(listOf(classifier, fakeAi))
        val d = SearchPolicy.decide(combined.classify(SearchNormalizer.normalize("hello")), all)
        assertEquals(RuleAction.BLOCK, d.action)
        assertEquals(Category.GORE, d.category)
        assertEquals("ai", d.ruleType)
    }
}

class SearchPolicyTest {
    private fun classification(vararg s: Pair<Category, Double>) =
        SearchClassification(mapOf(*s), listOf("r1"), "keyword")
    private val all = SearchPolicyConfig(true, Category.filterable.toSet())

    @Test fun categoryEnabledAndThresholdExceeded() =
        assertEquals(RuleAction.BLOCK, SearchPolicy.decide(classification(Category.DRUGS to 0.7), all).action)

    @Test fun thresholdNotExceeded() {
        val d = SearchPolicy.decide(classification(Category.DRUGS to 0.59), all)
        assertEquals(RuleAction.ALLOW, d.action)
        assertEquals("below_threshold", d.reason)
    }

    @Test fun thresholdIsInclusiveAndPerCategory() {
        assertEquals(RuleAction.BLOCK, SearchPolicy.decide(classification(Category.DRUGS to 0.6), all).action)
        val strictGore = all.copy(thresholds = mapOf(Category.GORE to 0.3))
        assertEquals(RuleAction.BLOCK, SearchPolicy.decide(classification(Category.GORE to 0.35), strictGore).action)
    }

    @Test fun categoryDisabled() {
        val d = SearchPolicy.decide(classification(Category.DRUGS to 1.0), all.copy(blockedCategories = emptySet()))
        assertEquals(RuleAction.ALLOW, d.action)
        assertEquals("category_disabled", d.reason)
    }

    @Test fun unknownAndSafeAllow() {
        assertEquals(RuleAction.ALLOW, SearchPolicy.decide(SearchClassification.unknown(), all).action)
        assertEquals(RuleAction.ALLOW, SearchPolicy.decide(classification(Category.SAFE to 1.0), all).action)
    }

    @Test fun multipleCategoriesHighestEnabledWins() {
        val d = SearchPolicy.decide(classification(Category.GAMBLING to 0.7, Category.VIOLENCE to 0.9), all)
        assertEquals(Category.VIOLENCE, d.category)
        assertEquals(0.9, d.confidence, 1e-9)
    }

    @Test fun searchProtectionOff() {
        val d = SearchPolicy.decide(classification(Category.SEXUAL to 1.0), SearchPolicyConfig.DISABLED)
        assertEquals(RuleAction.ALLOW, d.action)
        assertEquals("search_protection_off", d.reason)
    }
}

class SearchPrivacyTest {
    private val direct = java.util.concurrent.Executor { it.run() }
    private val key = ByteArray(32) { it.toByte() }

    private fun run(vararg queries: String): InMemoryBlockEventStore {
        val store = InMemoryBlockEventStore()
        var now = 0L
        val logger = BlockLogger(store, direct, clock = { now += 60_000; now })
        val service = RuleBasedSearchFilterService(
            RuleBasedSearchClassifier(),
            { SearchPolicyConfig(true, Category.filterable.toSet()) },
            SearchEventRecorder(logger, QueryHasher(key)),
        )
        queries.forEach { service.classify(SearchQuery("google", it)) }
        return store
    }

    private fun everything(store: InMemoryBlockEventStore) =
        store.recent(100).joinToString("|") { "${it.subject} ${it.category} ${it.source} ${it.ruleType} ${it.confidence}" }

    @Test fun originalSensitiveQueryIsNotWritten() {
        val store = run("my neighbour ahmad online casino at 5 main street")
        val events = store.recent(10)
        assertEquals(1, events.size)
        val e = events.single()
        assertEquals(EventSource.SEARCH, e.source)
        assertEquals(Category.GAMBLING, e.category)
        assertEquals("keyword", e.ruleType)
        val dump = everything(store).lowercase()
        for (word in listOf("neighbour", "ahmad", "casino", "main", "street", "online")) {
            assertFalse("leaked '$word' in $dump", dump.contains(word))
        }
        assertTrue(e.subject.matches(Regex("^ga0[12]#[0-9a-f]{8}$")))
    }

    @Test fun passwordAndTokensAreNotLogged() {
        val store = run(
            "porn password=Hunter2!secret",
            "casino Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def",
            "كازينو كلمة المرور 123456",
        )
        val dump = everything(store)
        for (secret in listOf("Hunter2", "secret", "eyJhbGci", "Bearer", "123456", "كلمة")) {
            assertFalse("leaked $secret", dump.contains(secret, ignoreCase = true))
        }
        assertEquals(3, store.recent(10).size)
    }

    @Test fun allowedQueriesAreNotLoggedAtAll() {
        assertEquals(0, run("weather tomorrow", "sex education").recent(10).size)
    }

    @Test fun hashIsKeyedStableAndShort() {
        val a = QueryHasher(key).shortHash("online casino")
        assertEquals(a, QueryHasher(key).shortHash("online casino"))
        assertNotEquals(a, QueryHasher(ByteArray(32) { 7 }).shortHash("online casino"))
        assertEquals(8, a.length)
    }

    @Test fun noOpServiceStillAvailable() {
        assertNull(com.safeguard.app.engine.search.NoOpSearchFilterService.classify(SearchQuery("g", "x")).ruleId)
    }
}

class LexiconIntegrityTest {
    @Test fun idsAreUniqueAndWeightsInRange() {
        val entries: List<LexiconEntry> = com.safeguard.app.engine.search.BuiltInSearchLexicon.entries
        assertEquals(entries.size, entries.map { it.id }.toSet().size)
        assertTrue(entries.all { it.weight in 0.0..1.0 && it.category.isFilterable })
        assertTrue(entries.all { SearchNormalizer.normalizeTerm(it.phrase).isNotEmpty() })
    }
}
