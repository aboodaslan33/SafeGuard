package com.safeguard.app.engine.ai

import com.safeguard.app.engine.rules.Category

enum class ContentKind { TEXT, IMAGE }

/** Content to classify. Held in memory only; never stored or logged. */
sealed interface ContentInput {
    val kind: ContentKind

    class Text(val text: String) : ContentInput {
        override val kind get() = ContentKind.TEXT
        override fun toString() = "Text(<redacted>)"
    }

    /** [declaredMime] is what the content provider claims; bytes decide. */
    class Image(val bytes: ByteArray, val declaredMime: String? = null) : ContentInput {
        override val kind get() = ContentKind.IMAGE
        override fun toString() = "Image(${bytes.size} bytes)"
    }
}

enum class ClassificationStatus {
    /** Scores are meaningful. */
    OK,

    /** The model ran but doesn't know this input well enough (→ UNKNOWN). */
    UNCERTAIN,

    /** No model / adapter for this kind, rate limited, or cloud not consented. */
    UNAVAILABLE,

    /** Input failed validation (size, type, malformed). */
    REJECTED,
}

/** Why an input was rejected or a classifier was unavailable. Stable ids. */
enum class ClassificationError(val id: String) {
    EMPTY_INPUT("empty_input"),
    FILE_TOO_LARGE("file_too_large"),
    UNSUPPORTED_TYPE("unsupported_type"),
    TYPE_MISMATCH("type_mismatch"),
    MALFORMED("malformed"),
    DIMENSIONS_TOO_LARGE("dimensions_too_large"),
    DECODE_FAILED("decode_failed"),
    NO_MODEL("no_model"),
    MODEL_INTEGRITY("model_integrity"),
    RATE_LIMITED("rate_limited"),
    NOT_CONSENTED("not_consented"),
    INTERNAL("internal"),
}

/**
 * Multi-label output: an independent 0..1 score per risk category (several
 * can be high at once) plus a SAFE score. Never contains the input.
 */
data class ClassificationResult(
    val status: ClassificationStatus,
    /** Risk categories → 0..1, plus [Category.SAFE]. Empty unless OK/UNCERTAIN. */
    val scores: Map<Category, Double> = emptyMap(),
    /** e.g. "sg-text-1"; null when no model ran. */
    val modelId: String? = null,
    val error: ClassificationError? = null,
    /** Wall time of the whole classify call, for benchmarks. */
    val elapsedMicros: Long = 0,
) {
    fun score(c: Category) = scores[c] ?: 0.0

    /** Highest-scoring risk category (not SAFE/UNKNOWN), or null. */
    val topRisk: Pair<Category, Double>?
        get() = scores.filterKeys { it.isFilterable }.maxByOrNull { it.value }?.toPair()

    companion object {
        fun unavailable(error: ClassificationError, modelId: String? = null) =
            ClassificationResult(ClassificationStatus.UNAVAILABLE, modelId = modelId, error = error)

        fun rejected(error: ClassificationError) =
            ClassificationResult(ClassificationStatus.REJECTED, error = error)

        /** SAFE = probability that no risk label applies (labels independent). */
        fun safeScore(risk: Map<Category, Double>): Double =
            risk.values.fold(1.0) { acc, p -> acc * (1.0 - p.coerceIn(0.0, 1.0)) }
    }
}

/**
 * The app's single entry point for AI classification. Implementations are
 * swappable (different models, local or cloud) without touching callers.
 */
interface ContentClassifier {
    fun classifyText(text: String): ClassificationResult
    fun classifyImage(bytes: ByteArray, declaredMime: String? = null): ClassificationResult
    fun classifyContent(input: ContentInput): ClassificationResult = when (input) {
        is ContentInput.Text -> classifyText(input.text)
        is ContentInput.Image -> classifyImage(input.bytes, input.declaredMime)
    }

    /** Whether any adapter can currently handle [kind]. */
    fun isAvailable(kind: ContentKind): Boolean
}

/** One model backend. Adapters never store or transmit input unless they say so. */
interface ClassifierAdapter {
    val id: String
    fun supports(kind: ContentKind): Boolean

    /** False when the model is missing, failed integrity, or needs consent. */
    val isAvailable: Boolean

    /** True if input leaves the device (requires consent; see CloudClassifierAdapter). */
    val isRemote: Boolean get() = false

    fun classify(input: ContentInput): ClassificationResult
}

/**
 * Routes each input to the first available adapter for its kind, local
 * adapters first. Remote adapters are skipped unless [allowRemote] says so
 * (explicit user consent).
 */
class AdapterContentClassifier(
    private val adapters: List<ClassifierAdapter>,
    private val allowRemote: () -> Boolean = { false },
    private val clock: () -> Long = System::nanoTime,
) : ContentClassifier {

    override fun classifyText(text: String) = classifyContent(ContentInput.Text(text))

    override fun classifyImage(bytes: ByteArray, declaredMime: String?) =
        classifyContent(ContentInput.Image(bytes, declaredMime))

    override fun isAvailable(kind: ContentKind) = pick(kind) != null

    override fun classifyContent(input: ContentInput): ClassificationResult {
        val adapter = pick(input.kind) ?: return ClassificationResult.unavailable(ClassificationError.NO_MODEL)
        val start = clock()
        val result = try {
            adapter.classify(input)
        } catch (e: OutOfMemoryError) {
            ClassificationResult.rejected(ClassificationError.DIMENSIONS_TOO_LARGE)
        } catch (e: Exception) {
            ClassificationResult.unavailable(ClassificationError.INTERNAL, adapter.id)
        }
        return result.copy(elapsedMicros = (clock() - start) / 1000)
    }

    private fun pick(kind: ContentKind): ClassifierAdapter? {
        val remoteOk = allowRemote()
        return adapters
            .filter { it.supports(kind) && it.isAvailable && (!it.isRemote || remoteOk) }
            .minByOrNull { if (it.isRemote) 1 else 0 }
    }
}
