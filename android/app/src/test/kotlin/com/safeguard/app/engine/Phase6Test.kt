package com.safeguard.app.engine

import com.safeguard.app.engine.ai.AdapterContentClassifier
import com.safeguard.app.engine.ai.GuardedContentClassifier
import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.InMemoryBlockEventStore
import com.safeguard.app.engine.logging.LogRetention
import com.safeguard.app.engine.privacy.MacProvider
import com.safeguard.app.engine.privacy.QueryHasher
import com.safeguard.app.engine.rules.Category
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Phase 6: log retention, key handling and source-level privacy checks. */
class Phase6Test {
    private val day = LogRetention.DAY_MS
    private var now = 100 * day
    private var retention = LogRetention.DAYS_30
    private val store = InMemoryBlockEventStore()
    private val logger = BlockLogger(store, { it.run() }, clock = { now }, retention = { retention })

    private fun block(ts: Long, subject: String) = logger.record(BlockEvent(ts, subject, Category.GAMBLING))

    // ---- Retention -----------------------------------------------------

    @Test fun retentionIds() {
        assertEquals(LogRetention.DAYS_7, LogRetention.fromId("7d"))
        assertEquals(LogRetention.DAYS_30, LogRetention.fromId("30d"))
        assertEquals(LogRetention.NEVER, LogRetention.fromId("never"))
        assertNull(LogRetention.fromId("forever"))
        assertEquals(LogRetention.DAYS_30, LogRetention.DEFAULT)
    }

    @Test fun neverKeepsNoEventRows() {
        retention = LogRetention.NEVER
        block(now, "casino.test")
        assertEquals(0, store.recent(10).size)
    }

    @Test fun switchingToSevenDaysPrunesOlderEvents() {
        block(now - 20 * day, "old.test")
        block(now - 3 * day, "recent.test")
        assertEquals(2, store.recent(10).size)
        retention = LogRetention.DAYS_7
        logger.applyRetention()
        assertEquals(listOf("recent.test"), store.recent(10).map { it.subject })
    }

    @Test fun switchingToNeverDeletesRowsButKeepsLifetimeCounter() {
        block(now - day, "a.test")
        block(now, "b.test")
        retention = LogRetention.NEVER
        logger.applyRetention()
        assertEquals(0, store.recent(10).size)
        assertEquals(2L, store.lifetimeTotal())
    }

    @Test fun periodicPruneUsesCurrentSetting() {
        retention = LogRetention.DAYS_7
        block(now - 10 * day, "stale.test")
        repeat(200) { block(now + it * 60_000L, "s$it.test") }
        assertTrue(store.recent(1000).none { it.subject == "stale.test" })
    }

    // ---- Keys ----------------------------------------------------------

    @Test fun macProviderMatchesPlainHmac() {
        val key = ByteArray(32) { it.toByte() }
        val expected = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }
            .doFinal("x".toByteArray())
        assertTrue(expected.contentEquals(MacProvider.fromBytes(key).newMac().doFinal("x".toByteArray())))
        assertEquals(QueryHasher(key).shortHash("casino"), QueryHasher(MacProvider.fromBytes(key)).shortHash("casino"))
        assertNotEquals(QueryHasher(key).shortHash("casino"), QueryHasher(ByteArray(32)).shortHash("casino"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun shortKeysRejected() {
        MacProvider.fromBytes(ByteArray(8))
    }

    @Test fun guardedClassifierAcceptsProvider() {
        val g = GuardedContentClassifier(AdapterContentClassifier(emptyList()), MacProvider.fromBytes(ByteArray(32) { 3 }))
        g.classifyText("hello")
        g.clear()
    }

    // ---- Source audit (static checks over the shipped sources) ---------

    private val root: File = (
        listOfNotNull(System.getProperty("sg.assets")?.let { File(it) }, File("").absoluteFile)
            .flatMap { generateSequence(it) { f -> f.parentFile }.toList() }
            .firstOrNull { File(it, "android/app/src/main").isDirectory && File(it, "lib").isDirectory }
        ) ?: error("project root not found")

    private fun sources(dir: String, ext: String) =
        File(root, dir).walkTopDown().filter { it.isFile && it.extension == ext }.toList()
            .also { assertTrue("no sources under $dir", it.isNotEmpty()) }

    @Test fun noRawKeyInSharedPreferences() {
        val offenders = sources("android/app/src/main/kotlin", "kt").filter {
            val t = it.readText()
            t.contains("putString(KEY_HASH") || t.contains("fun hashKey()")
        }
        assertTrue(offenders.toString(), offenders.isEmpty())
    }

    @Test fun androidLogsNeverIncludeVariables() {
        // Every Log.x call passes a constant message plus at most an
        // exception *class name* or a bundled asset path: no domains,
        // queries, URLs, exception messages or stack traces.
        val call = Regex("""Log\.[vdiwe]\(([^\n]*)\)""")
        val allowed = Regex("""\$\{(e\.javaClass\.simpleName|spec\.assetPath)\}""")
        val bad = sources("android/app/src/main/kotlin", "kt").flatMap { f ->
            call.findAll(f.readText()).map { it.groupValues[1] }.filter { args ->
                val rest = allowed.replace(args, "")
                rest.contains('$') || rest.contains("+ ") || rest.trimEnd().endsWith(", e") || rest.contains(", e,")
            }.map { "${f.name}: $it" }.toList()
        }
        assertTrue(bad.joinToString("\n"), bad.isEmpty())
    }

    @Test fun noCleartextEndpointsOrWebViews() {
        val http = Regex("""["']http://(?!schemas\.android\.com)""")
        val bad = (sources("lib", "dart") + sources("android/app/src/main/kotlin", "kt")).filter {
            val t = it.readText()
            http.containsMatchIn(t) || t.contains("WebView")
        }
        assertTrue(bad.toString(), bad.isEmpty())
    }
}
