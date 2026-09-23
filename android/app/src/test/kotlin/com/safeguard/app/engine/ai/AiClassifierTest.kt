package com.safeguard.app.engine.ai

import com.safeguard.app.engine.ai.model.BuiltInModels
import com.safeguard.app.engine.ai.model.ModelIntegrityException
import com.safeguard.app.engine.ai.model.ModelLoader
import com.safeguard.app.engine.ai.model.ModelSpec
import com.safeguard.app.engine.ai.text.LocalTextClassifierAdapter
import com.safeguard.app.engine.ai.text.TextFeatures
import com.safeguard.app.engine.ai.text.TextModel
import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.logging.InMemoryBlockEventStore
import com.safeguard.app.engine.privacy.QueryHasher
import com.safeguard.app.engine.privacy.SearchEventRecorder
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.search.RuleBasedSearchClassifier
import com.safeguard.app.engine.search.SearchPolicyConfig
import com.safeguard.app.engine.search.SearchQuery
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File

private fun localText() = LocalTextClassifierAdapter(BuiltInModels.TEXT_V1.id, { ModelFiles.shipped })

/** The shipped on-device text model, through the real adapter. */
class LocalTextModelTest {
    private val classifier = AdapterContentClassifier(listOf(localText()))
    private val normal = DecisionPolicy(true, Category.filterable.toSet(), AiSettings())

    private fun decide(text: String, p: DecisionPolicy = normal) =
        ProtectionDecisionEngine.decide(RuleSignal.None, classifier.classifyText(text), p, EventSource.SEARCH)

    @Test fun eachCategoryIsRecognised() {
        val cases = mapOf(
            "watch free porn" to Category.SEXUAL,
            "street fight video" to Category.VIOLENCE,
            "صور جثث حقيقية" to Category.GORE,
            "online betting site" to Category.GAMBLING,
            "buy cocaine online" to Category.DRUGS,
            "ways to kill myself" to Category.DANGEROUS,
        )
        for ((text, category) in cases) {
            val d = decide(text)
            assertEquals(text, FinalAction.BLOCK, d.action)
            assertEquals(text, category, d.category)
            assertEquals(BuiltInModels.TEXT_V1.id, d.modelId)
        }
    }

    @Test fun safeQueriesAndLookAlikesAreNotBlocked() {
        for (text in listOf(
            "weather today", "cake recipe", "sex education", "sexual health", "breast cancer",
            "drug interactions", "gore-tex jacket", "kill process linux", "suicide hotline", "الطقس اليوم",
        )) {
            assertFalse(text, decide(text).blocks)
        }
        assertEquals(FinalAction.ALLOW, decide("weather today").action)
    }

    @Test fun unknownWordsAreUncertainNotBlocked() {
        val r = classifier.classifyText("xyzzy qwerty")
        assertEquals(ClassificationStatus.UNCERTAIN, r.status)
        assertEquals(FinalAction.UNKNOWN, decide("xyzzy qwerty").action)
    }

    @Test fun scoresAreMultiLabelAndIndependent() {
        val r = classifier.classifyText("beheading murder video")
        assertTrue(r.score(Category.GORE) > 0.9)
        assertTrue(r.score(Category.VIOLENCE) > 0.5)
        assertTrue(r.scores.keys.containsAll(Category.filterable))
        assertTrue(r.score(Category.SAFE) < 0.1)
    }

    @Test fun strictModeCatchesMoreThanNormal() {
        // "naked pictures": sexual ≈ 0.70 — below NORMAL (0.90), at STRICT (0.70).
        val strict = normal.copy(ai = AiSettings(mode = DetectionMode.STRICT))
        val r = classifier.classifyText("naked pictures")
        assertTrue(r.score(Category.SEXUAL) in 0.6..0.9)
        assertFalse(decide("naked pictures").blocks)
        assertEquals(r.score(Category.SEXUAL) >= 0.70, decide("naked pictures", strict).blocks)
    }

    @Test fun emptyInputIsRejected() {
        assertEquals(ClassificationStatus.REJECTED, classifier.classifyText("   ").status)
    }

    @Test fun featureHashingIsStable() {
        // Pinned: a change here silently invalidates the shipped model.
        assertEquals(TextFeatures.index("w:casino"), TextFeatures.index("w:casino"))
        val a = TextFeatures.extract("Online  CASINO!")
        val b = TextFeatures.extract("online casino")
        assertArrayEquals(a.indices, b.indices)
        assertTrue(a.indices.all { it in 0 until TextFeatures.DIM })
    }
}

class ModelIntegrityTest {
    private val spec = BuiltInModels.TEXT_V1
    private val good = ModelFiles.textAsset.readBytes()
    private fun loader(bytes: ByteArray?) = ModelLoader { if (bytes == null) null else ByteArrayInputStream(bytes) }

    @Test fun shippedModelVerifiesAndParses() {
        val m = TextModel.parse(loader(good).load(spec))
        assertEquals(6, m.labels.size)
    }

    @Test fun tamperedModelIsRefused() {
        val bad = good.copyOf().also { it[5000] = (it[5000] + 1).toByte() }
        expectIntegrity { loader(bad).load(spec) }
    }

    @Test fun truncatedOrPaddedModelIsRefused() {
        expectIntegrity { loader(good.copyOf(good.size - 1)).load(spec) }
        expectIntegrity { loader(good + byteArrayOf(0)).load(spec) }
        expectIntegrity { loader(null).load(spec) }
    }

    @Test fun onlyManifestModelsCanLoad() {
        val foreign = spec.copy(id = "evil", assetPath = "../../evil.bin")
        try {
            loader(good).load(foreign)
            fail()
        } catch (e: IllegalArgumentException) {
            // expected
        }
    }

    @Test fun parserRejectsMalformedModels() {
        fun rejects(b: ByteArray) = try { TextModel.parse(b); false } catch (e: IllegalArgumentException) { true }
        assertTrue(rejects(ByteArray(0)))
        assertTrue(rejects(good.copyOf(100)))
        assertTrue(rejects(good.copyOf().also { it[0] = 'X'.code.toByte() }))
        // NaN weight: first weight float starts after header+labels+biases.
        val nan = good.copyOf()
        val firstWeight = good.size - 1024 - 4 * 6 * TextFeatures.DIM
        java.nio.ByteBuffer.wrap(nan).order(java.nio.ByteOrder.LITTLE_ENDIAN).putFloat(firstWeight, Float.NaN)
        assertTrue(rejects(nan))
    }

    @Test fun integrityFailureMakesAdapterUnavailableNotGuessing() {
        val adapter = LocalTextClassifierAdapter("t", { throw ModelIntegrityException("checksum mismatch") })
        assertFalse(adapter.isAvailable)
        val c = AdapterContentClassifier(listOf(adapter))
        assertEquals(ClassificationStatus.UNAVAILABLE, c.classifyText("online casino").status)
    }

    @Test fun noImageModelIsBundled() {
        assertNull(BuiltInModels.forKind(ContentKind.IMAGE))
        for (s: ModelSpec in BuiltInModels.all) {
            assertTrue(File(ModelFiles.assets, s.assetPath).isFile)
            assertTrue(s.license.isNotBlank() && s.provenance.isNotBlank())
        }
    }

    private fun expectIntegrity(block: () -> Unit) {
        try {
            block()
            fail("expected integrity failure")
        } catch (e: ModelIntegrityException) {
            // expected
        }
    }
}

class ClassifierRoutingTest {
    @Test fun routesByKindAndReportsMissingAdapter() {
        val text = MockClassifierAdapter(setOf(ContentKind.TEXT), scores = mapOf(Category.SEXUAL to 0.9))
        val c = AdapterContentClassifier(listOf(text))
        assertEquals(ClassificationStatus.OK, c.classifyText("x").status)
        assertEquals(ClassificationError.NO_MODEL, c.classifyImage(byteArrayOf(1)).error)
        assertTrue(c.isAvailable(ContentKind.TEXT))
        assertFalse(c.isAvailable(ContentKind.IMAGE))
    }

    @Test fun adapterIsSwappableWithoutTouchingCallers() {
        val a = MockClassifierAdapter(id = "a", scores = mapOf(Category.GAMBLING to 0.95))
        val b = MockClassifierAdapter(id = "b", scores = mapOf(Category.DRUGS to 0.95))
        assertEquals("a", AdapterContentClassifier(listOf(a)).classifyText("q").modelId)
        assertEquals("b", AdapterContentClassifier(listOf(b)).classifyText("q").modelId)
    }

    @Test fun adapterCrashBecomesUnavailable() {
        val crashing = object : ClassifierAdapter {
            override val id = "crash"
            override fun supports(kind: ContentKind) = true
            override val isAvailable = true
            override fun classify(input: ContentInput): ClassificationResult = throw IllegalStateException()
        }
        val r = AdapterContentClassifier(listOf(crashing)).classifyText("q")
        assertEquals(ClassificationStatus.UNAVAILABLE, r.status)
    }

    @Test fun contentInputNeverPrintsText() {
        assertFalse(ContentInput.Text("secret query").toString().contains("secret"))
    }
}

class CloudAdapterTest {
    private class RecordingTransport(override val isEncrypted: Boolean) : CloudTransport {
        var calls = 0
        override fun classify(input: ContentInput): ClassificationResult {
            calls++
            return MockClassifierAdapter.result(Category.SEXUAL to 0.99)
        }
    }

    @Test fun cloudIsNeverUsedWithoutConsent() {
        val t = RecordingTransport(true)
        val cloud = CloudClassifierAdapter({ CloudConsent.NONE }, t)
        assertFalse(cloud.isAvailable)
        assertEquals(ClassificationError.NOT_CONSENTED, cloud.classify(ContentInput.Text("x")).error)
        assertEquals(0, t.calls)
    }

    @Test fun cloudNeedsCurrentDisclosureAndEncryption() {
        val old = CloudClassifierAdapter({ CloudConsent(true, 0) }, RecordingTransport(true))
        assertFalse(old.isAvailable)
        val plain = CloudClassifierAdapter({ CloudConsent(true, CloudConsent.CURRENT_DISCLOSURE) }, RecordingTransport(false))
        assertFalse(plain.isAvailable)
        assertFalse(CloudClassifierAdapter({ CloudConsent(true, CloudConsent.CURRENT_DISCLOSURE) }, null).isAvailable)
    }

    @Test fun localIsPreferredAndRemoteSkippedUnlessAllowed() {
        val t = RecordingTransport(true)
        val cloud = CloudClassifierAdapter({ CloudConsent(true, CloudConsent.CURRENT_DISCLOSURE) }, t)
        val none = AdapterContentClassifier(listOf(cloud), allowRemote = { false })
        assertEquals(ClassificationError.NO_MODEL, none.classifyImage(byteArrayOf(1)).error)
        val local = MockClassifierAdapter(id = "local")
        assertEquals("local", AdapterContentClassifier(listOf(cloud, local), allowRemote = { true }).classifyText("q").modelId)
        assertEquals(0, t.calls)
    }
}

class GuardsTest {
    private val key = ByteArray(32) { it.toByte() }

    @Test fun cacheAvoidsRecomputation() {
        val mock = MockClassifierAdapter(scores = mapOf(Category.GAMBLING to 0.95))
        val g = GuardedContentClassifier(AdapterContentClassifier(listOf(mock)), key)
        repeat(5) { g.classifyText("online casino") }
        assertEquals(1, mock.calls)
        g.classifyText("another")
        assertEquals(2, mock.calls)
    }

    @Test fun failuresAreNotCached() {
        val mock = MockClassifierAdapter(status = ClassificationStatus.OK)
        mock.available = false
        val g = GuardedContentClassifier(AdapterContentClassifier(listOf(mock)), key)
        g.classifyText("q")
        mock.available = true
        g.classifyText("q")
        assertEquals(1, mock.calls)
    }

    @Test fun rateLimitReportsUnavailableAndRecovers() {
        var now = 0L
        val budget = InferenceBudget(mapOf(ContentKind.TEXT to 3), clock = { now })
        val mock = MockClassifierAdapter()
        val g = GuardedContentClassifier(AdapterContentClassifier(listOf(mock)), key, budget)
        repeat(3) { assertEquals(ClassificationStatus.OK, g.classifyText("q$it").status) }
        val limited = g.classifyText("q9")
        assertEquals(ClassificationError.RATE_LIMITED, limited.error)
        assertEquals(
            FinalAction.UNKNOWN,
            ProtectionDecisionEngine.decide(RuleSignal.None, limited, DecisionPolicy(true, Category.filterable.toSet(), AiSettings()), EventSource.SEARCH).action,
        )
        now = 60_001
        assertEquals(ClassificationStatus.OK, g.classifyText("q9").status)
        assertEquals(4, mock.calls)
    }
}

/** Rule engine first, AI second, and nothing sensitive reaches the log. */
class AiSearchIntegrationTest {
    private val store = InMemoryBlockEventStore()
    private val logger = BlockLogger(store, { it.run() }, clock = { 1_000L })
    private val stats = InMemoryAiStatsStore()
    private var ai = AiSettings()
    private var categories = Category.filterable.toSet()
    private val mock = MockClassifierAdapter()

    private fun service(classifier: ContentClassifier = AdapterContentClassifier(listOf(mock))) = AiSearchFilterService(
        rules = RuleBasedSearchClassifier(),
        config = { SearchPolicyConfig(true, categories) },
        ai = classifier,
        aiSettings = { ai },
        listener = SearchEventRecorder(logger, QueryHasher(ByteArray(32) { 7 })),
        aiListener = AiStatsRecorder(stats),
    )

    @Test fun knownBlockedQueryIsBlockedByRulesWithoutRunningAi() {
        val d = service().classify(SearchQuery("google", "online casino"))
        assertEquals(RuleAction.BLOCK, d.action)
        assertEquals("keyword", d.ruleType)
        assertEquals(0, mock.calls)
        assertEquals(EventSource.SEARCH, store.recent(1).single().source)
    }

    @Test fun unknownQueryGoesToAiWhichCanBlock() {
        mock.scores = mapOf(Category.VIOLENCE to 0.96)
        val d = service().classify(SearchQuery("google", "some unseen violent phrasing"))
        assertEquals(RuleAction.BLOCK, d.action)
        assertEquals(Category.VIOLENCE, d.category)
        assertEquals(AiSearchFilterService.RULE_TYPE_AI_TEXT, d.ruleType)
        val e: BlockEvent = store.recent(1).single()
        assertEquals(EventSource.AI, e.source)
        assertTrue(e.subject.matches(Regex("mock#[0-9a-f]{8}")))
        assertFalse(e.subject.contains("violent"))
        assertEquals(1, stats.read().blocks)
        assertEquals(1L, stats.read().detectionsByCategory[Category.VIOLENCE])
    }

    @Test fun uncertainOrLowConfidenceAiIsAllowedAndNotLogged() {
        mock.scores = mapOf(Category.SEXUAL to 0.7)
        assertEquals(RuleAction.ALLOW, service().classify(SearchQuery("google", "ambiguous words")).action)
        mock.status = ClassificationStatus.UNCERTAIN
        mock.scores = mapOf(Category.SEXUAL to 0.99)
        assertEquals(RuleAction.ALLOW, service().classify(SearchQuery("google", "gibberish")).action)
        assertTrue(store.recent(10).isEmpty())
    }

    @Test fun aiOffMeansPhase3Behaviour() {
        ai = AiSettings.OFF
        mock.scores = mapOf(Category.SEXUAL to 0.99)
        assertEquals(RuleAction.ALLOW, service().classify(SearchQuery("google", "unseen phrase")).action)
        assertEquals(0, mock.calls)
    }

    @Test fun realModelEndToEnd() {
        val real = AdapterContentClassifier(listOf(localText()))
        val d = service(real).classify(SearchQuery("google", "street fight video"))
        assertEquals(RuleAction.BLOCK, d.action)
        assertEquals(Category.VIOLENCE, d.category)
        assertEquals(RuleAction.ALLOW, service(real).classify(SearchQuery("google", "cake recipe")).action)
    }

    @Test fun detectionInDisabledCategoryCountsButDoesNotBlock() {
        categories = categories - Category.DRUGS
        mock.scores = mapOf(Category.DRUGS to 0.99)
        assertEquals(RuleAction.ALLOW, service().classify(SearchQuery("google", "unseen phrase")).action)
        assertEquals(1, stats.read().detections)
        assertEquals(0, stats.read().blocks)
    }
}

class FalsePositiveTest {
    @Test fun reportStoresOnlyAllowedFieldsRounded() {
        val r = FalsePositiveReport.of(5L, EventSource.AI, Category.SEXUAL, 0.91234)
        assertEquals(0.91, r.confidence, 1e-9)
        assertEquals(FalsePositiveReport.VERDICT_INCORRECT_BLOCK, r.verdict)
        // The record type has exactly these properties — no content field exists.
        val fields = FalsePositiveReport::class.java.declaredFields
            .filterNot { java.lang.reflect.Modifier.isStatic(it.modifiers) }.map { it.name }.toSet()
        assertEquals(setOf("timestamp", "source", "category", "confidence", "verdict"), fields)
    }

    @Test fun reportsAreCountedPerCategoryAndCleared() {
        val s = InMemoryAiStatsStore()
        s.addReport(FalsePositiveReport.of(1, EventSource.AI, Category.GORE, 0.9))
        s.addReport(FalsePositiveReport.of(2, EventSource.SEARCH, Category.GORE, 0.8))
        assertEquals(2, s.read().falsePositiveReports)
        assertEquals(2L, s.read().reportsByCategory[Category.GORE])
        assertEquals(2L, s.reports(10).first().timestamp)
        s.clear()
        assertEquals(AiStatistics(), s.read())
    }
}
