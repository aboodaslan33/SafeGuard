package com.safeguard.app.engine.ai.text

import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.search.NormalizedQuery
import com.safeguard.app.engine.search.SearchNormalizer
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.exp
import kotlin.math.sqrt

/**
 * Sparse, L2-normalised feature vector for one text. Features are hashed
 * (so the model stores no vocabulary): word unigrams, word bigrams and
 * character 3/4-grams of each word.
 */
class TextFeatureVector(
    val indices: IntArray,
    val values: FloatArray,
    /** Distinct hashed word-unigram features (for model coverage). */
    val wordIndices: IntArray,
)

object TextFeatures {
    const val DIM = 8192

    fun extract(raw: String): TextFeatureVector = extract(SearchNormalizer.normalize(raw))

    fun extract(q: NormalizedQuery): TextFeatureVector {
        val counts = HashMap<Int, Float>()
        val words = LinkedHashSet<Int>()
        fun add(feature: String, weight: Float = 1f) {
            val i = index(feature)
            counts[i] = (counts[i] ?: 0f) + weight
        }

        val tokens = q.tokens.map { SearchNormalizer.squeeze(it, 2) }
        for ((k, t) in tokens.withIndex()) {
            add("w:$t")
            words += index("w:$t")
            // Arabic article/prefix-stripped form ("والقمار" → "قمار").
            for (v in SearchNormalizer.variants(t)) {
                if (v != t && v.length >= 2 && !t.startsWith(v)) {
                    add("w:$v", 0.5f)
                    words += index("w:$v")
                }
            }
            if (k > 0) add("b:${tokens[k - 1]} $t")
            val padded = "^$t$"
            for (n in 3..4) {
                if (padded.length < n) continue
                for (s in 0..padded.length - n) add("c:" + padded.substring(s, s + n), 0.5f)
            }
        }

        val sorted = counts.keys.sorted().toIntArray()
        val values = FloatArray(sorted.size) { counts.getValue(sorted[it]) }
        var norm = 0.0
        for (v in values) norm += v * v
        val inv = if (norm > 0) (1.0 / sqrt(norm)).toFloat() else 0f
        for (i in values.indices) values[i] *= inv
        return TextFeatureVector(sorted, values, words.toIntArray())
    }

    /** FNV-1a (32-bit) over UTF-16 code units; stable across platforms. */
    fun index(feature: String): Int {
        var h = 0x811C9DC5.toInt()
        for (ch in feature) {
            h = h xor ch.code
            h *= 0x01000193
        }
        return (h and 0x7FFFFFFF) % DIM
    }
}

/**
 * Multi-label logistic regression: one independent sigmoid per risk
 * category, so a text can score high on several at once.
 *
 * Binary format (little-endian), validated strictly by [parse]:
 * ```
 * "SGTM" | u16 version=1 | i32 dim | u8 nLabels | nLabels × (u8 len, ASCII id)
 * | f32 bias[nLabels] | f32 weights[nLabels][dim] | u8 knownWords[dim/8]
 * ```
 * `knownWords` is a bitset of word features seen in training, used to
 * report when an input is mostly unknown to the model.
 */
class TextModel(
    val labels: List<Category>,
    val dim: Int,
    private val bias: FloatArray,
    private val weights: Array<FloatArray>,
    private val knownWords: ByteArray,
) {
    init {
        require(labels.isNotEmpty() && labels.all { it.isFilterable })
        require(bias.size == labels.size && weights.size == labels.size)
        require(weights.all { it.size == dim } && knownWords.size == dim / 8)
    }

    fun predict(v: TextFeatureVector): Map<Category, Double> {
        val out = LinkedHashMap<Category, Double>(labels.size)
        for ((l, category) in labels.withIndex()) {
            var z = bias[l].toDouble()
            val w = weights[l]
            for (k in v.indices.indices) z += w[v.indices[k]] * v.values[k]
            out[category] = 1.0 / (1.0 + exp(-z))
        }
        return out
    }

    /** Fraction of the input's words the model saw during training (0..1). */
    fun coverage(v: TextFeatureVector): Double {
        if (v.wordIndices.isEmpty()) return 0.0
        val known = v.wordIndices.count { isKnown(it) }
        return known.toDouble() / v.wordIndices.size
    }

    private fun isKnown(i: Int) = (knownWords[i ushr 3].toInt() shr (i and 7)) and 1 == 1

    fun serialize(): ByteArray {
        val labelBytes = labels.sumOf { 1 + it.id.length }
        val size = 4 + 2 + 4 + 1 + labelBytes + 4 * labels.size + 4 * labels.size * dim + dim / 8
        val b = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
        b.put(MAGIC).putShort(VERSION.toShort()).putInt(dim).put(labels.size.toByte())
        for (c in labels) {
            b.put(c.id.length.toByte())
            b.put(c.id.toByteArray(Charsets.US_ASCII))
        }
        bias.forEach { b.putFloat(it) }
        weights.forEach { row -> row.forEach { b.putFloat(it) } }
        b.put(knownWords)
        return b.array()
    }

    companion object {
        private val MAGIC = "SGTM".toByteArray(Charsets.US_ASCII)
        const val VERSION = 1

        fun knownWordsBitset(dim: Int, indices: Collection<Int>): ByteArray {
            val bits = ByteArray(dim / 8)
            for (i in indices) bits[i ushr 3] = (bits[i ushr 3].toInt() or (1 shl (i and 7))).toByte()
            return bits
        }

        /** Parses and validates a model file. Throws [IllegalArgumentException] on any defect. */
        fun parse(bytes: ByteArray): TextModel {
            val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            fun need(n: Int) = require(b.remaining() >= n) { "truncated model" }
            need(11)
            val magic = ByteArray(4).also { b.get(it) }
            require(magic.contentEquals(MAGIC)) { "bad magic" }
            require(b.short.toInt() == VERSION) { "unsupported version" }
            val dim = b.int
            require(dim == TextFeatures.DIM) { "dimension mismatch" }
            val n = b.get().toInt() and 0xFF
            require(n in 1..Category.filterable.size) { "bad label count" }
            val labels = ArrayList<Category>(n)
            repeat(n) {
                need(1)
                val len = b.get().toInt() and 0xFF
                need(len)
                val id = ByteArray(len).also { b.get(it) }.toString(Charsets.US_ASCII)
                val c = Category.fromId(id)
                require(c != null && c.isFilterable && c !in labels) { "bad label" }
                labels += c
            }
            val expected = 4L * n + 4L * n * dim + dim / 8
            require(b.remaining().toLong() == expected) { "size mismatch" }
            val bias = FloatArray(n) { b.float }
            val weights = Array(n) { FloatArray(dim) { b.float } }
            require(bias.all { it.isFinite() } && weights.all { r -> r.all { it.isFinite() } }) { "non-finite weight" }
            val known = ByteArray(dim / 8).also { b.get(it) }
            return TextModel(labels, dim, bias, weights, known)
        }
    }
}
