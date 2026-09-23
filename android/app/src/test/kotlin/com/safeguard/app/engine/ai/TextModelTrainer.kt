package com.safeguard.app.engine.ai

import com.safeguard.app.engine.ai.text.TextFeatureVector
import com.safeguard.app.engine.ai.text.TextFeatures
import com.safeguard.app.engine.ai.text.TextModel
import com.safeguard.app.engine.rules.Category
import kotlin.math.exp
import kotlin.math.sqrt

/**
 * Build-time trainer for the shipped text model (test sources only; not in
 * the app). Deterministic: fixed data order, full-batch gradient descent in
 * double precision, no randomness — the same seed file always produces the
 * same bytes, which `TextModelBuildTest` checks against the shipped asset.
 */
object TextModelTrainer {
    val LABELS = listOf(
        Category.SEXUAL, Category.VIOLENCE, Category.GORE,
        Category.GAMBLING, Category.DRUGS, Category.DANGEROUS,
    )

    data class Example(val text: String, val labels: Set<Category>)

    fun parse(tsv: String): List<Example> = tsv.lineSequence()
        .map { it.trimEnd() }
        .filter { it.isNotEmpty() && !it.startsWith("#") }
        .map { line ->
            val tab = line.indexOf('\t')
            require(tab > 0) { "bad line: $line" }
            val labels = line.substring(0, tab).split(',').map { it.trim() }
                .filter { it != "safe" }
                .map { requireNotNull(Category.fromId(it)) { "bad label in: $line" } }
                .toSet()
            Example(line.substring(tab + 1).trim(), labels)
        }.toList()

    fun train(examples: List<Example>, epochs: Int = 2000, lr: Double = 4.0, l2: Double = 1e-5): TextModel {
        val dim = TextFeatures.DIM
        val feats: List<TextFeatureVector> = examples.map { TextFeatures.extract(it.text) }
        val bias = FloatArray(LABELS.size)
        val weights = Array(LABELS.size) { FloatArray(dim) }
        for ((l, label) in LABELS.withIndex()) {
            val y = examples.map { if (label in it.labels) 1.0 else 0.0 }
            val pos = y.count { it > 0 }.coerceAtLeast(1)
            val neg = (y.size - pos).coerceAtLeast(1)
            // Mild rebalancing: positives are rare per label.
            val pw = sqrt(neg.toDouble() / pos)
            val w = DoubleArray(dim)
            var b = 0.0
            val grad = DoubleArray(dim)
            repeat(epochs) {
                grad.fill(0.0)
                var gb = 0.0
                var norm = 0.0
                for ((i, f) in feats.withIndex()) {
                    var z = b
                    for (k in f.indices.indices) z += w[f.indices[k]] * f.values[k]
                    val p = 1.0 / (1.0 + exp(-z))
                    val sw = if (y[i] > 0) pw else 1.0
                    val e = (p - y[i]) * sw
                    norm += sw
                    gb += e
                    for (k in f.indices.indices) grad[f.indices[k]] += e * f.values[k]
                }
                for (j in 0 until dim) w[j] -= lr * (grad[j] / norm + l2 * w[j])
                b -= lr * gb / norm
            }
            weights[l] = FloatArray(dim) { w[it].toFloat() }
            bias[l] = b.toFloat()
        }
        val known = feats.flatMap { it.wordIndices.asList() }.toSet()
        return TextModel(LABELS, dim, bias, weights, TextModel.knownWordsBitset(dim, known))
    }
}
