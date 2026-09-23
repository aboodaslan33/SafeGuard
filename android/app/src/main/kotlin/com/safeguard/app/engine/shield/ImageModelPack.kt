package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.ClassificationStatus
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.image.ModelInputSpec
import java.nio.ByteBuffer
import java.security.MessageDigest

/** Which inference runtime a pack needs. Only data formats: never code. */
enum class ImageRuntimeKind(val id: String, val fileExtension: String) {
    ONNX("onnx", "onnx"),
    TFLITE("tflite", "tflite");

    companion object {
        fun fromId(id: String?) = entries.firstOrNull { it.id == id }
    }
}

/** Whether the model's output vector is already probabilities. */
enum class OutputKind(val id: String) {
    SOFTMAX("softmax"),
    LOGITS("logits");

    companion object {
        fun fromId(id: String?) = entries.firstOrNull { it.id == id }
    }
}

/**
 * Everything SafeGuard must know to run an image model, in a strict
 * `key=value` manifest (same style as the signed update manifest):
 *
 * ```
 * format=sg-image-pack/1
 * id=example-nsfw
 * version=1
 * runtime=onnx
 * sizeBytes=5712345
 * sha256=<64 hex>
 * inputSize=224
 * layout=nchw
 * mean=0.485,0.456,0.406
 * std=0.229,0.224,0.225
 * output=softmax
 * labels=safe,sexual            (model output order → AiLabel ids; a label may
 *                                repeat: its probabilities are added)
 * minConfidence=0.50
 * license=Apache-2.0
 * provenance=<where weights and training data come from>
 * ```
 *
 * Unknown keys, repeated keys, unknown labels or out-of-range values are
 * rejected: a pack is either fully understood or not used.
 */
data class ImageModelPack(
    val id: String,
    val version: Int,
    val runtime: ImageRuntimeKind,
    val sizeBytes: Long,
    val sha256: String,
    val input: ModelInputSpec,
    val layout: TensorLayout,
    val output: OutputKind,
    val labels: List<AiLabel>,
    val minConfidence: Double,
    val license: String,
    val provenance: String,
) {
    /** e.g. "example-nsfw@1": what logs and the UI show as the model version. */
    val modelVersion: String get() = "$id@$version"

    /** Where the model file lives in the APK's assets (stored uncompressed). */
    val assetPath: String get() = "models/$id.${runtime.fileExtension}"

    companion object {
        const val FORMAT = "sg-image-pack/1"
        const val MAX_MODEL_BYTES = 32L * 1024 * 1024
        private val KEYS = setOf(
            "format", "id", "version", "runtime", "sizeBytes", "sha256", "inputSize", "layout",
            "mean", "std", "output", "labels", "minConfidence", "license", "provenance",
        )
        private val ID = Regex("^[a-z0-9][a-z0-9.-]{0,39}$")
        private val HEX64 = Regex("^[0-9a-f]{64}$")

        fun parse(text: String): ImageModelPack {
            require(text.length <= 4_096) { "manifest too large" }
            val kv = LinkedHashMap<String, String>()
            for (raw in text.lines()) {
                val line = raw.trim()
                if (line.isEmpty() || line.startsWith("#")) continue
                val eq = line.indexOf('=')
                require(eq > 0) { "malformed line" }
                val k = line.substring(0, eq)
                val v = line.substring(eq + 1).trim()
                require(k in KEYS) { "unknown key" }
                require(kv.put(k, v) == null) { "duplicate key" }
                require(v.isNotEmpty() && v.length <= 400 && v.none { it.isISOControl() }) { "bad value" }
            }
            require(kv.keys == KEYS) { "missing key" }
            require(kv["format"] == FORMAT) { "unsupported format" }
            val id = kv.getValue("id").also { require(ID.matches(it)) { "bad id" } }
            val version = kv.getValue("version").toIntOrNull()?.takeIf { it in 1..1_000_000 } ?: error("bad version")
            val runtime = ImageRuntimeKind.fromId(kv["runtime"]) ?: error("unsupported runtime")
            val size = kv.getValue("sizeBytes").toLongOrNull()?.takeIf { it in 1..MAX_MODEL_BYTES } ?: error("bad size")
            val sha = kv.getValue("sha256").also { require(HEX64.matches(it)) { "bad sha256" } }
            val inputSize = kv.getValue("inputSize").toIntOrNull()?.takeIf { it in 32..512 } ?: error("bad input size")
            val layout = TensorLayout.fromId(kv["layout"]) ?: error("bad layout")
            val mean = floats(kv.getValue("mean"))
            val std = floats(kv.getValue("std"))
            require(std.all { it > 0f }) { "bad std" }
            val output = OutputKind.fromId(kv["output"]) ?: error("bad output")
            val labels = kv.getValue("labels").split(',').map { AiLabel.fromId(it.trim()) ?: error("unknown label") }
            require(labels.size in 2..32) { "bad labels" }
            require(AiLabel.SAFE in labels && labels.any { it.isRisk }) { "need SAFE and a risk label" }
            require(AiLabel.UNKNOWN !in labels) { "UNKNOWN is not a model output" }
            val minConfidence = kv.getValue("minConfidence").toDoubleOrNull()?.takeIf { it in 0.0..1.0 } ?: error("bad minConfidence")
            return ImageModelPack(
                id, version, runtime, size, sha, ModelInputSpec(inputSize, mean, std), layout, output, labels,
                minConfidence, kv.getValue("license"), kv.getValue("provenance"),
            )
        }

        private fun floats(v: String): FloatArray {
            val parts = v.split(',').map { it.trim().toFloatOrNull()?.takeIf { f -> f.isFinite() && f in -10f..10f } ?: error("bad number") }
            require(parts.size == 3) { "need 3 channels" }
            return parts.toFloatArray()
        }
    }
}

/**
 * Image model packs this build may load, pinned by id, version and SHA-256
 * (like `BuiltInModels`). Nothing else can be loaded.
 */
object BuiltInImagePacks {
    /**
     * GantMan nsfw_model v1.1.0, MobileNetV2 140/224, the official
     * `saved_model.tflite` from the GitHub release, unmodified. MIT license.
     * Classes (alphabetical, the model's output order): drawings, hentai,
     * neutral, porn, sexy. Input: 224×224 RGB scaled to 0..1 (the
     * project's own preprocessing). Training data was scraped from the web
     * (nsfw_data_scraper): provenance accepted by the project owner, see
     * docs/AI_CONTENT_SHIELD.md §4.
     */
    val GANTMAN_NSFW_MNV2: ImageModelPack = ImageModelPack.parse(
        """
        format=sg-image-pack/1
        id=gantman-nsfw-mnv2
        version=110
        runtime=tflite
        sizeBytes=24414436
        sha256=6d9271fd927ef46328e8168babeaf4169abed8f5808d79383f448f90c67f36d4
        inputSize=224
        layout=nhwc
        mean=0,0,0
        std=1,1,1
        output=softmax
        labels=safe,sexual,safe,sexual,suggestive
        minConfidence=0.40
        license=MIT (GantMan/nsfw_model, Copyright (c) 2020 The nsfw_model Developers)
        provenance=GantMan/nsfw_model release 1.1.0 (MobileNetV2 transfer learning); web-scraped training data
        """.trimIndent(),
    )

    val all: List<ImageModelPack> = listOf(GANTMAN_NSFW_MNV2)
}

/** Runs one model. Implementations wrap an inference runtime; they execute no downloaded code. */
interface ImageInferenceRuntime : AutoCloseable {
    /** One output per pack label, in pack order. */
    fun run(input: FloatArray): FloatArray
}

/** Opens a runtime for a verified model (a read-only, possibly memory-mapped buffer). */
fun interface ImageRuntimeFactory {
    fun open(pack: ImageModelPack, model: ByteBuffer): ImageInferenceRuntime
}

/** Why image classification can't run. [id] goes to the UI and diagnostics. */
enum class ImageModelState(val id: String) {
    /** No pinned pack in this build (the shipped state). */
    NOT_BUNDLED("not_bundled"),

    /** No runtime compiled in for the pack's format. */
    NO_RUNTIME("no_runtime"),

    /** Bytes missing, wrong size or wrong SHA-256. */
    CORRUPTED("corrupted"),

    /** The runtime failed to load the model (unsupported device, bad file). */
    LOAD_FAILED("load_failed"),
    OUT_OF_MEMORY("out_of_memory"),
    READY("ready"),

    /** Loaded on demand; not loaded yet. */
    NOT_LOADED("not_loaded"),
}

/**
 * On-device screen-frame classification with one [ImageModelPack].
 *
 * The model is loaded once, on first use, only after its bytes match the
 * pinned size and SHA-256, and released by [close] (when protection or the
 * shield stops). The input tensor is reused across frames and cleared
 * after each run. Any failure makes the result UNAVAILABLE, never a guess.
 */
class ShieldImageClassifier(
    private val pack: ImageModelPack?,
    /** Maps or reads the model file (e.g. from assets); null if missing. */
    private val readModel: (ImageModelPack) -> ByteBuffer?,
    /** Null when no runtime for the pack's format is compiled in. */
    private val runtimes: (ImageRuntimeKind) -> ImageRuntimeFactory?,
) : AutoCloseable {

    private var runtime: ImageInferenceRuntime? = null
    private var tensor: FloatArray? = null

    @Volatile var state: ImageModelState = if (pack == null) ImageModelState.NOT_BUNDLED else ImageModelState.NOT_LOADED
        private set

    val modelVersion: String? get() = pack?.modelVersion

    val isUsable: Boolean
        get() = state == ImageModelState.READY || state == ImageModelState.NOT_LOADED

    @Synchronized
    fun classify(frame: RgbaFrame): AiClassification {
        val p = pack ?: return AiClassification.unavailable(ContentKind.IMAGE, ClassificationStatus.UNAVAILABLE)
        val rt = runtime ?: load(p) ?: return AiClassification.unavailable(ContentKind.IMAGE, ClassificationStatus.UNAVAILABLE, p.modelVersion)
        val input = tensor ?: FloatArray(p.input.tensorLength).also { tensor = it }
        return try {
            FramePreprocessor.toTensor(frame, p.input, p.layout, input)
            val raw = rt.run(input)
            val probs = probabilities(raw, p) ?: return AiClassification.unavailable(ContentKind.IMAGE, ClassificationStatus.UNAVAILABLE, p.modelVersion)
            // A label may appear more than once (e.g. drawings + neutral = SAFE).
            val byLabel = LinkedHashMap<AiLabel, Double>()
            p.labels.forEachIndexed { i, l -> byLabel[l] = (byLabel[l] ?: 0.0) + probs[i] }
            AiClassification.fromProbabilities(byLabel, p.modelVersion, p.minConfidence)
        } catch (e: OutOfMemoryError) {
            release(ImageModelState.OUT_OF_MEMORY)
            AiClassification.unavailable(ContentKind.IMAGE, ClassificationStatus.UNAVAILABLE, p.modelVersion)
        } catch (e: Exception) {
            AiClassification.unavailable(ContentKind.IMAGE, ClassificationStatus.UNAVAILABLE, p.modelVersion)
        } finally {
            input.fill(0f)
        }
    }

    /** Frees the model and buffers. The next [classify] reloads (if the model is intact). */
    @Synchronized
    override fun close() {
        if (state == ImageModelState.READY) release(ImageModelState.NOT_LOADED)
    }

    /**
     * Allows one more load after a transient failure (out of memory, load
     * error). A corrupted model stays unusable until the app is updated.
     */
    @Synchronized
    fun resetAfterFailure() {
        if (state == ImageModelState.OUT_OF_MEMORY || state == ImageModelState.LOAD_FAILED) state = ImageModelState.NOT_LOADED
    }

    private fun load(p: ImageModelPack): ImageInferenceRuntime? {
        if (state != ImageModelState.NOT_LOADED) return null
        val factory = runtimes(p.runtime)
        if (factory == null) {
            state = ImageModelState.NO_RUNTIME
            return null
        }
        val bytes = try {
            readModel(p)
        } catch (e: Exception) {
            null
        }
        if (bytes == null || bytes.capacity().toLong() != p.sizeBytes || !sha256Matches(bytes, p.sha256)) {
            state = ImageModelState.CORRUPTED
            return null
        }
        return try {
            factory.open(p, bytes).also {
                runtime = it
                state = ImageModelState.READY
            }
        } catch (e: OutOfMemoryError) {
            state = ImageModelState.OUT_OF_MEMORY
            null
        } catch (e: Exception) {
            state = ImageModelState.LOAD_FAILED
            null
        }
    }

    private fun release(next: ImageModelState) {
        try {
            runtime?.close()
        } catch (_: Exception) {
        }
        runtime = null
        tensor = null
        state = next
    }

    companion object {
        /** Validates the output vector and turns it into probabilities; null if unusable. */
        fun probabilities(raw: FloatArray, pack: ImageModelPack): DoubleArray? {
            if (raw.size != pack.labels.size || raw.any { !it.isFinite() }) return null
            return when (pack.output) {
                OutputKind.LOGITS -> {
                    val max = raw.max()
                    val exps = DoubleArray(raw.size) { Math.exp((raw[it] - max).toDouble()) }
                    val sum = exps.sum()
                    DoubleArray(raw.size) { exps[it] / sum }
                }
                OutputKind.SOFTMAX -> {
                    if (raw.any { it < -1e-4f || it > 1f + 1e-4f }) return null
                    val sum = raw.sum().toDouble()
                    if (sum !in 0.98..1.02) return null
                    DoubleArray(raw.size) { raw[it].toDouble().coerceIn(0.0, 1.0) / sum }
                }
            }
        }

        fun sha256Matches(buffer: ByteBuffer, hex: String): Boolean {
            val digest = MessageDigest.getInstance("SHA-256").apply { update(buffer.duplicate().also { it.clear() }) }.digest()
            val expected = ByteArray(32) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
            return MessageDigest.isEqual(digest, expected)
        }
    }
}
