package com.safeguard.app.engine.ai.text

import com.safeguard.app.engine.ai.ClassificationError
import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ClassificationStatus
import com.safeguard.app.engine.ai.ClassifierAdapter
import com.safeguard.app.engine.ai.ContentInput
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.search.SearchNormalizer

/**
 * On-device text classification. The model is loaded lazily on first use
 * (never at app start) by [loadModel], which must verify integrity; a load
 * failure makes the adapter unavailable rather than guessing.
 */
class LocalTextClassifierAdapter(
    override val id: String,
    private val loadModel: () -> TextModel,
    /** Below this fraction of known words the result is UNCERTAIN. */
    private val minCoverage: Double = MIN_COVERAGE,
) : ClassifierAdapter {

    @Volatile private var model: TextModel? = null
    @Volatile private var failed = false

    override fun supports(kind: ContentKind) = kind == ContentKind.TEXT

    override val isAvailable: Boolean get() = !failed && (model != null || tryLoad() != null)

    override fun classify(input: ContentInput): ClassificationResult {
        val text = (input as? ContentInput.Text)?.text
            ?: return ClassificationResult.rejected(ClassificationError.UNSUPPORTED_TYPE)
        val m = model ?: tryLoad() ?: return ClassificationResult.unavailable(ClassificationError.MODEL_INTEGRITY, id)
        val normalized = SearchNormalizer.normalize(text)
        if (normalized.isEmpty) return ClassificationResult.rejected(ClassificationError.EMPTY_INPUT)

        val features = TextFeatures.extract(normalized)
        val risk = m.predict(features)
        val scores = risk + (Category.SAFE to ClassificationResult.safeScore(risk))
        val status = if (m.coverage(features) < minCoverage) ClassificationStatus.UNCERTAIN else ClassificationStatus.OK
        return ClassificationResult(status, scores, id)
    }

    /**
     * Allows one more load attempt after a failure (called by the health
     * monitor with backoff; a broken model is never retried in a loop).
     */
    @Synchronized
    fun resetFailure() {
        failed = false
    }

    @Synchronized
    private fun tryLoad(): TextModel? {
        model?.let { return it }
        if (failed) return null
        return try {
            loadModel().also { model = it }
        } catch (e: Exception) {
            failed = true
            null
        }
    }

    companion object {
        const val MIN_COVERAGE = 0.34
    }
}
