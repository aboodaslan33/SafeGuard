package com.safeguard.app.engine.ai

import com.safeguard.app.engine.ai.model.BuiltInModels
import com.safeguard.app.engine.ai.model.ModelLoader
import com.safeguard.app.engine.ai.text.TextFeatures
import com.safeguard.app.engine.ai.text.TextModel
import com.safeguard.app.engine.search.RuleBasedSearchClassifier
import com.safeguard.app.engine.search.SearchNormalizer
import com.safeguard.app.engine.search.SearchPolicy
import com.safeguard.app.engine.search.SearchPolicyConfig
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.RuleAction
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Shared access to the seed set and the shipped asset. */
object ModelFiles {
    val assets = File(System.getProperty("sg.assets") ?: "src/main/assets")
    val textAsset get() = File(assets, BuiltInModels.TEXT_V1.assetPath)
    fun seed(): List<TextModelTrainer.Example> =
        TextModelTrainer.parse(ModelFiles::class.java.getResource("/ai/text_seed_v1.tsv")!!.readText())

    /** The shipped model, loaded through the real integrity-checking loader. */
    val shipped: TextModel by lazy {
        TextModel.parse(ModelLoader { path -> File(assets, path).takeIf { it.isFile }?.inputStream() }.load(BuiltInModels.TEXT_V1))
    }
}

class TextModelBuildTest {

    /**
     * The shipped asset must be exactly what the trainer produces from the
     * seed set (no hand-edited or foreign weights). Set SG_WRITE_MODEL=1 to
     * regenerate after changing the seed set, then update the pinned
     * size/SHA-256 in BuiltInModels.
     */
    @Test fun shippedModelIsReproducibleFromSeedSet() {
        val bytes = TextModelTrainer.train(ModelFiles.seed()).serialize()
        if (System.getenv("SG_WRITE_MODEL") == "1") {
            ModelFiles.textAsset.parentFile.mkdirs()
            ModelFiles.textAsset.writeBytes(bytes)
            println("size=${bytes.size} sha256=${ModelLoader.sha256Hex(bytes)}")
            return
        }
        assertArrayEquals(bytes, ModelFiles.textAsset.readBytes())
        assertEquals(BuiltInModels.TEXT_V1.sizeBytes, bytes.size.toLong())
        assertEquals(BuiltInModels.TEXT_V1.sha256, ModelLoader.sha256Hex(bytes))
    }

    /**
     * Held-out evaluation (every 5th seed example is held out, the model is
     * trained on the rest). Numbers are written to build/ai-eval.txt and
     * copied into docs/PHASE_4_AI.md. The asserts are floors that catch a
     * broken build, not quality claims.
     */
    @Test fun heldOutEvaluation() {
        val all = ModelFiles.seed()
        val test = all.filterIndexed { i, _ -> i % 5 == 2 }
        val model = TextModelTrainer.train(all.filterIndexed { i, _ -> i % 5 != 2 })
        val rules = RuleBasedSearchClassifier()
        val cfg = SearchPolicyConfig(true, Category.filterable.toSet())
        val report = StringBuilder("held-out examples: ${test.size} (${test.count { it.labels.isEmpty() }} safe)\n")
        var safeFpAt07 = 0
        for (th in listOf(0.5, 0.7, 0.85, 0.9)) {
            var tp = 0; var fn = 0; var fp = 0; var safeFp = 0; var combinedHit = 0; var risky = 0
            for (e in test) {
                val scores = model.predict(TextFeatures.extract(e.text))
                val pred = scores.filter { it.value >= th }.keys
                tp += (pred intersect e.labels).size
                fn += (e.labels - pred).size
                fp += (pred - e.labels).size
                if (e.labels.isEmpty() && pred.isNotEmpty()) safeFp++
                if (e.labels.isNotEmpty()) {
                    risky++
                    val ruleBlock = SearchPolicy.decide(rules.classify(SearchNormalizer.normalize(e.text)), cfg).action == RuleAction.BLOCK
                    if (ruleBlock || pred.isNotEmpty()) combinedHit++
                }
            }
            if (th == 0.7) safeFpAt07 = safeFp
            report.append(
                "threshold %.2f: label recall %.2f (%d/%d), label false positives %d, safe queries flagged %d, rules+AI caught %d/%d risky\n"
                    .format(th, tp.toDouble() / (tp + fn), tp, tp + fn, fp, safeFp, combinedHit, risky),
            )
        }
        File("build").mkdirs()
        File("build/ai-eval.txt").writeText(report.toString())
        assertTrue(report.toString(), safeFpAt07 <= 2)
    }

    @Test fun seedSetIsWellFormed() {
        val all = ModelFiles.seed()
        assertTrue(all.size > 300)
        for (label in TextModelTrainer.LABELS) assertTrue(label.id, all.count { label in it.labels } >= 30)
        assertTrue(all.count { it.labels.isEmpty() } >= 150)
        assertEquals("duplicate texts", all.size, all.map { SearchNormalizer.normalize(it.text).text }.toSet().size)
    }
}
