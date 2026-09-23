package com.safeguard.app.engine.ai.image

import com.safeguard.app.engine.ai.ClassificationError
import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ClassificationStatus
import com.safeguard.app.engine.ai.ClassifierAdapter
import com.safeguard.app.engine.ai.ContentInput
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.rules.Category

enum class ImageFormat(val mime: String) { JPEG("image/jpeg"), PNG("image/png"), WEBP("image/webp") }

/** Hard limits applied before any pixel is decoded. */
data class ImageLimits(
    val maxBytes: Int = 15 * 1024 * 1024,
    val maxSide: Int = 16_384,
    val maxPixels: Long = 50_000_000,
    /** Upper bound for the *decoded* (sampled) ARGB buffer. */
    val maxDecodedBytes: Long = 16L * 1024 * 1024,
)

data class ImageHeader(val format: ImageFormat, val width: Int, val height: Int)

class ImageRejectedException(val error: ClassificationError) : Exception(error.id)

/**
 * Identifies the format from the file's own bytes (magic numbers, not the
 * name or declared MIME type) and reads the dimensions from the header,
 * with every offset bounds-checked. Nothing is decoded here.
 */
object ImageHeaderParser {

    fun parse(bytes: ByteArray, declaredMime: String? = null, limits: ImageLimits = ImageLimits()): ImageHeader {
        if (bytes.isEmpty()) throw ImageRejectedException(ClassificationError.EMPTY_INPUT)
        if (bytes.size > limits.maxBytes) throw ImageRejectedException(ClassificationError.FILE_TOO_LARGE)
        val format = sniff(bytes) ?: throw ImageRejectedException(ClassificationError.UNSUPPORTED_TYPE)
        if (declaredMime != null && declaredMime.startsWith("image/") && declaredMime != format.mime &&
            !(format == ImageFormat.JPEG && declaredMime == "image/jpg")
        ) {
            throw ImageRejectedException(ClassificationError.TYPE_MISMATCH)
        }
        val (w, h) = when (format) {
            ImageFormat.PNG -> png(bytes)
            ImageFormat.JPEG -> jpeg(bytes)
            ImageFormat.WEBP -> webp(bytes)
        } ?: throw ImageRejectedException(ClassificationError.MALFORMED)
        if (w <= 0 || h <= 0) throw ImageRejectedException(ClassificationError.MALFORMED)
        if (w > limits.maxSide || h > limits.maxSide || w.toLong() * h > limits.maxPixels) {
            throw ImageRejectedException(ClassificationError.DIMENSIONS_TOO_LARGE)
        }
        return ImageHeader(format, w, h)
    }

    fun sniff(b: ByteArray): ImageFormat? = when {
        b.size >= 3 && u8(b, 0) == 0xFF && u8(b, 1) == 0xD8 && u8(b, 2) == 0xFF -> ImageFormat.JPEG
        b.size >= 8 && PNG_SIG.indices.all { u8(b, it) == PNG_SIG[it] } -> ImageFormat.PNG
        b.size >= 12 && ascii(b, 0, 4) == "RIFF" && ascii(b, 8, 4) == "WEBP" -> ImageFormat.WEBP
        else -> null
    }

    private fun png(b: ByteArray): Pair<Int, Int>? {
        // Signature, then the IHDR chunk must come first.
        if (b.size < 24 || ascii(b, 12, 4) != "IHDR") return null
        return be32(b, 16) to be32(b, 20)
    }

    private fun jpeg(b: ByteArray): Pair<Int, Int>? {
        var i = 2
        var guard = 0
        while (i + 4 <= b.size && guard++ < 10_000) {
            if (u8(b, i) != 0xFF) return null
            val marker = u8(b, i + 1)
            if (marker == 0xFF) { i++; continue } // fill byte
            if (marker == 0xD8 || marker in 0xD0..0xD7 || marker == 0x01) { i += 2; continue }
            if (marker == 0xD9 || marker == 0xDA) return null // EOI / start of scan before a frame header
            val len = be16(b, i + 2)
            if (len < 2 || i + 2 + len > b.size) return null
            val isSof = marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if (isSof) {
                if (len < 7) return null
                return be16(b, i + 7) to be16(b, i + 5)
            }
            i += 2 + len
        }
        return null
    }

    private fun webp(b: ByteArray): Pair<Int, Int>? {
        if (b.size < 30) return null
        return when (ascii(b, 12, 4)) {
            "VP8 " -> {
                if (u8(b, 23) != 0x9D || u8(b, 24) != 0x01 || u8(b, 25) != 0x2A) return null
                (le16(b, 26) and 0x3FFF) to (le16(b, 28) and 0x3FFF)
            }
            "VP8L" -> {
                if (u8(b, 20) != 0x2F) return null
                val bits = le32(b, 21)
                ((bits and 0x3FFF) + 1) to (((bits ushr 14) and 0x3FFF) + 1)
            }
            "VP8X" -> (le24(b, 24) + 1) to (le24(b, 27) + 1)
            else -> null
        }
    }

    private val PNG_SIG = intArrayOf(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    private fun u8(b: ByteArray, i: Int) = b[i].toInt() and 0xFF
    private fun be16(b: ByteArray, i: Int) = (u8(b, i) shl 8) or u8(b, i + 1)
    private fun be32(b: ByteArray, i: Int) = (u8(b, i) shl 24) or (u8(b, i + 1) shl 16) or (u8(b, i + 2) shl 8) or u8(b, i + 3)
    private fun le16(b: ByteArray, i: Int) = u8(b, i) or (u8(b, i + 1) shl 8)
    private fun le24(b: ByteArray, i: Int) = u8(b, i) or (u8(b, i + 1) shl 8) or (u8(b, i + 2) shl 16)
    private fun le32(b: ByteArray, i: Int) = le24(b, i) or (u8(b, i + 3) shl 24)
    private fun ascii(b: ByteArray, i: Int, n: Int) = String(b, i, n, Charsets.ISO_8859_1)
}

/** Decoded ARGB pixels. [close] releases the backing memory (Android: recycles the bitmap). */
interface DecodedImage : AutoCloseable {
    val width: Int
    val height: Int

    /** ARGB_8888 pixels, row-major. Valid until [close]. */
    val pixels: IntArray
}

/** Decodes with power-of-two subsampling so the full image never sits in memory. */
fun interface ImageDecoder {
    fun decode(bytes: ByteArray, header: ImageHeader, sampleSize: Int): DecodedImage
}

/** What the model expects: square RGB input, NHWC float, per-channel normalisation. */
data class ModelInputSpec(
    val size: Int = 224,
    val mean: FloatArray = floatArrayOf(0.5f, 0.5f, 0.5f),
    val std: FloatArray = floatArrayOf(0.5f, 0.5f, 0.5f),
) {
    val tensorLength: Int get() = size * size * 3
}

object ImagePreprocessor {

    /** Largest power of two keeping both sides ≥ [target] (like BitmapFactory.inSampleSize). */
    fun sampleSize(width: Int, height: Int, target: Int): Int {
        var s = 1
        while (width / (s * 2) >= target && height / (s * 2) >= target) s *= 2
        return s
    }

    fun decodedBytes(header: ImageHeader, sampleSize: Int): Long {
        val w = (header.width + sampleSize - 1) / sampleSize
        val h = (header.height + sampleSize - 1) / sampleSize
        return w.toLong() * h * 4
    }

    /**
     * Area-averaged resize to spec.size × spec.size (aspect ratio not kept:
     * classifiers of this kind are trained on squashed inputs), then
     * normalised to NHWC floats. Alpha is composited on white.
     */
    fun toTensor(img: DecodedImage, spec: ModelInputSpec, out: FloatArray = FloatArray(spec.tensorLength)): FloatArray {
        require(out.size == spec.tensorLength)
        val n = spec.size
        val px = img.pixels
        require(px.size >= img.width * img.height)
        for (y in 0 until n) {
            val y0 = y * img.height / n
            val y1 = maxOf(y0 + 1, (y + 1) * img.height / n)
            for (x in 0 until n) {
                val x0 = x * img.width / n
                val x1 = maxOf(x0 + 1, (x + 1) * img.width / n)
                var r = 0L; var g = 0L; var b = 0L
                for (yy in y0 until y1) {
                    val row = yy * img.width
                    for (xx in x0 until x1) {
                        val p = px[row + xx]
                        val a = (p ushr 24) and 0xFF
                        r += blend((p shr 16) and 0xFF, a)
                        g += blend((p shr 8) and 0xFF, a)
                        b += blend(p and 0xFF, a)
                    }
                }
                val count = ((y1 - y0) * (x1 - x0)).toFloat()
                val o = (y * n + x) * 3
                out[o] = ((r / count / 255f) - spec.mean[0]) / spec.std[0]
                out[o + 1] = ((g / count / 255f) - spec.mean[1]) / spec.std[1]
                out[o + 2] = ((b / count / 255f) - spec.mean[2]) / spec.std[2]
            }
        }
        return out
    }

    private fun blend(c: Int, a: Int) = (c * a + 255 * (255 - a)) / 255
}

/** An image model backend (e.g. a TFLite interpreter). Not bundled in this version. */
interface ImageModelRuntime : AutoCloseable {
    val modelId: String
    val input: ModelInputSpec

    /** Output order: one probability per entry. */
    val labels: List<Category>
    fun run(tensor: FloatArray): FloatArray
}

/**
 * On-device image classification:
 * validate header → plan subsampling → check decoded size → decode →
 * resize/normalise → infer → release everything.
 *
 * Nothing is written to disk; pixel and tensor buffers are cleared after
 * use. With no runtime ([runtime] returns null) the adapter is unavailable
 * and reports so, rather than returning a made-up score.
 */
class LocalImageClassifierAdapter(
    override val id: String,
    private val decoder: ImageDecoder,
    private val runtime: () -> ImageModelRuntime?,
    private val limits: ImageLimits = ImageLimits(),
) : ClassifierAdapter {

    override fun supports(kind: ContentKind) = kind == ContentKind.IMAGE

    override val isAvailable: Boolean get() = runtime() != null

    /** Validates only (no model needed); throws [ImageRejectedException]. */
    fun validate(bytes: ByteArray, declaredMime: String?): ImageHeader =
        ImageHeaderParser.parse(bytes, declaredMime, limits)

    override fun classify(input: ContentInput): ClassificationResult {
        val image = input as? ContentInput.Image
            ?: return ClassificationResult.rejected(ClassificationError.UNSUPPORTED_TYPE)
        val header = try {
            validate(image.bytes, image.declaredMime)
        } catch (e: ImageRejectedException) {
            return ClassificationResult.rejected(e.error)
        }
        val model = runtime() ?: return ClassificationResult.unavailable(ClassificationError.NO_MODEL)
        val spec = model.input
        val sample = ImagePreprocessor.sampleSize(header.width, header.height, spec.size)
        if (ImagePreprocessor.decodedBytes(header, sample) > limits.maxDecodedBytes) {
            return ClassificationResult.rejected(ClassificationError.DIMENSIONS_TOO_LARGE)
        }
        val tensor = FloatArray(spec.tensorLength)
        try {
            val decoded = try {
                decoder.decode(image.bytes, header, sample)
            } catch (e: ImageRejectedException) {
                return ClassificationResult.rejected(e.error)
            } catch (e: Exception) {
                return ClassificationResult.rejected(ClassificationError.DECODE_FAILED)
            }
            decoded.use { ImagePreprocessor.toTensor(it, spec, tensor) }
            val out = model.run(tensor)
            if (out.size != model.labels.size || out.any { !it.isFinite() }) {
                return ClassificationResult.unavailable(ClassificationError.INTERNAL, model.modelId)
            }
            val risk = LinkedHashMap<Category, Double>()
            model.labels.forEachIndexed { i, c ->
                if (c.isFilterable) risk[c] = out[i].toDouble().coerceIn(0.0, 1.0)
            }
            val safe = model.labels.indexOf(Category.SAFE).takeIf { it >= 0 }?.let { out[it].toDouble() }
                ?: ClassificationResult.safeScore(risk)
            return ClassificationResult(ClassificationStatus.OK, risk + (Category.SAFE to safe), model.modelId)
        } finally {
            tensor.fill(0f)
        }
    }
}
