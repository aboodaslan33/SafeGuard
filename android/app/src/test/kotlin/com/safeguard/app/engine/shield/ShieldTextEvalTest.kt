package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.ContentInput
import com.safeguard.app.engine.ai.DecisionPolicy
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.ai.FinalAction
import com.safeguard.app.engine.ai.ModelFiles
import com.safeguard.app.engine.ai.RuleSignal
import com.safeguard.app.engine.ai.text.LocalTextClassifierAdapter
import com.safeguard.app.engine.rules.Category
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Real measurement, not a mock: the shipped `sg-text-1` model (loaded
 * through the integrity-checking loader) on page-style text it was not
 * trained on (`ai/page_text_eval_v1.tsv`), decided by the real policy
 * engine. Results go to build/shield-eval.txt and docs/AI_CONTENT_SHIELD.md.
 * The assertions pin the measured numbers so a model or policy change that
 * shifts them is noticed; they are not quality targets.
 */
class ShieldTextEvalTest {

    private data class Example(val label: String, val text: String)

    private val examples: List<Example> =
        javaClass.getResource("/ai/page_text_eval_v1.tsv")!!.readText().lines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split('\t', limit = 2).let { p -> Example(p[0], p[1]) } }

    private val adapter = LocalTextClassifierAdapter("sg-text-1", { ModelFiles.shipped })

    private fun action(e: Example, mode: DetectionMode): Pair<FinalAction, AiClassification> {
        val c = AiClassification.fromText(adapter.classify(ContentInput.Text(e.text)))
        val policy = DecisionPolicy(true, Category.filterable.toSet(), AiSettings(enabled = true, mode = mode))
        val evidence = ShieldScores.toResult(c, ShieldScores.blockSuggestive(mode))
        return ShieldPolicy.decide(RuleSignal.None, evidence, c, policy).decision.action to c
    }

    @Test fun pageTextEvaluation() {
        val report = StringBuilder("sg-text-1 on page-style text (${examples.size} examples; JVM, not a phone)\n")
        val counts = LinkedHashMap<String, IntArray>() // group → [n, blockedNormal, blockedStrict, unknownNormal, rightCategoryNormal]
        for (e in examples) {
            val group = if (e.label == "safe" || e.label == "news") e.label else "risky"
            val (normal, c) = action(e, DetectionMode.NORMAL)
            val (strict, _) = action(e, DetectionMode.STRICT)
            val row = counts.getOrPut(group) { IntArray(5) }
            row[0]++
            if (normal == FinalAction.BLOCK) row[1]++
            if (strict == FinalAction.BLOCK) row[2]++
            if (normal == FinalAction.UNKNOWN) row[3]++
            if (normal == FinalAction.BLOCK && c.label.id == e.label) row[4]++
            report.append("%-9s normal=%-7s strict=%-7s top=%s %.2f | %s\n".format(e.label, normal, strict, c.label.id, c.confidence, e.text))
        }
        report.append("\n")
        for ((g, r) in counts) {
            report.append("%s: n=%d blocked NORMAL=%d STRICT=%d, UNKNOWN(NORMAL)=%d, right category=%d\n".format(g, r[0], r[1], r[2], r[3], r[4]))
        }

        // Latency on this machine's JVM for page-sized text (not a phone).
        val text = examples.joinToString("\n") { it.text }.take(2_000)
        repeat(50) { adapter.classify(ContentInput.Text(text)) }
        val times = LongArray(200) {
            val t0 = System.nanoTime()
            adapter.classify(ContentInput.Text(text))
            System.nanoTime() - t0
        }.sorted()
        report.append("latency, 2,000-char text: median %.0f µs, p95 %.0f µs (JVM)\n".format(times[100] / 1000.0, times[190] / 1000.0))
        File("build").mkdirs()
        File("build/shield-eval.txt").writeText(report.toString())
        println(report)

        val safe = counts.getValue("safe")
        val risky = counts.getValue("risky")
        assertEquals(40, safe[0])
        assertEquals(21, risky[0])
        // Pinned measurements (see docs/AI_CONTENT_SHIELD.md §Measured).
        assertEquals("safe text blocked in NORMAL", SAFE_BLOCKED_NORMAL, safe[1])
        assertEquals("safe text blocked in STRICT", SAFE_BLOCKED_STRICT, safe[2])
        assertEquals("risky text blocked in NORMAL", RISKY_BLOCKED_NORMAL, risky[1])
        assertEquals("risky text blocked in STRICT", RISKY_BLOCKED_STRICT, risky[2])
        assertTrue(times[100] < 50_000_000) // sanity: < 50 ms
    }

    companion object {
        const val SAFE_BLOCKED_NORMAL = 0
        const val SAFE_BLOCKED_STRICT = 0
        const val RISKY_BLOCKED_NORMAL = 13
        const val RISKY_BLOCKED_STRICT = 16
    }
}
