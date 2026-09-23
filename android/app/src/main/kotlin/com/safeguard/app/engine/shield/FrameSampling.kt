package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.image.ModelInputSpec
import java.nio.ByteBuffer

/**
 * A captured screen frame as the platform hands it over (e.g. an
 * `ImageReader` RGBA_8888 plane), read in place: no bitmap is created and
 * nothing is copied except the few pixels the model and hash need.
 * Never stored; the owner closes the underlying image right after use.
 */
class RgbaFrame(
    val width: Int,
    val height: Int,
    val buffer: ByteBuffer,
    /** Bytes between the starts of two rows (≥ width × pixelStride). */
    val rowStride: Int,
    /** Bytes between two pixels in a row (4 for RGBA_8888). */
    val pixelStride: Int = 4,
) {
    init {
        require(width in 1..MAX_SIDE && height in 1..MAX_SIDE) { "frame size" }
        require(pixelStride >= 4 && rowStride >= width * pixelStride) { "strides" }
        require(buffer.capacity().toLong() >= (height - 1).toLong() * rowStride + width.toLong() * pixelStride) { "buffer too small" }
    }

    private fun base(x: Int, y: Int) = y * rowStride + x * pixelStride
    fun r(x: Int, y: Int) = buffer.get(base(x, y)).toInt() and 0xFF
    fun g(x: Int, y: Int) = buffer.get(base(x, y) + 1).toInt() and 0xFF
    fun b(x: Int, y: Int) = buffer.get(base(x, y) + 2).toInt() and 0xFF

    override fun toString() = "RgbaFrame(${width}x$height)"

    companion object {
        const val MAX_SIDE = 4096
    }
}

enum class TensorLayout(val id: String) {
    /** [1, H, W, 3] — TFLite convention. */
    NHWC("nhwc"),

    /** [1, 3, H, W] — PyTorch / ONNX convention. */
    NCHW("nchw");

    companion object {
        fun fromId(id: String?) = entries.firstOrNull { it.id == id }
    }
}

object FramePreprocessor {
    /** Samples per output cell side; bounds CPU per frame (≤ 16 reads per input pixel). */
    const val MAX_SAMPLES_PER_CELL = 4

    /**
     * Area-averaged downscale of the whole frame to spec.size², normalised
     * with the model's mean/std, written into [out] (reused between
     * frames, so no allocation per frame).
     */
    fun toTensor(frame: RgbaFrame, spec: ModelInputSpec, layout: TensorLayout, out: FloatArray): FloatArray {
        require(out.size == spec.tensorLength) { "tensor size" }
        val n = spec.size
        val plane = n * n
        for (y in 0 until n) {
            val y0 = y * frame.height / n
            val y1 = maxOf(y0 + 1, (y + 1) * frame.height / n)
            val ys = maxOf(1, (y1 - y0) / MAX_SAMPLES_PER_CELL)
            for (x in 0 until n) {
                val x0 = x * frame.width / n
                val x1 = maxOf(x0 + 1, (x + 1) * frame.width / n)
                val xs = maxOf(1, (x1 - x0) / MAX_SAMPLES_PER_CELL)
                var r = 0; var g = 0; var b = 0; var count = 0
                var yy = y0
                while (yy < y1) {
                    var xx = x0
                    while (xx < x1) {
                        r += frame.r(xx, yy); g += frame.g(xx, yy); b += frame.b(xx, yy)
                        count++
                        xx += xs
                    }
                    yy += ys
                }
                val rf = (r.toFloat() / count / 255f - spec.mean[0]) / spec.std[0]
                val gf = (g.toFloat() / count / 255f - spec.mean[1]) / spec.std[1]
                val bf = (b.toFloat() / count / 255f - spec.mean[2]) / spec.std[2]
                when (layout) {
                    TensorLayout.NHWC -> {
                        val o = (y * n + x) * 3
                        out[o] = rf; out[o + 1] = gf; out[o + 2] = bf
                    }
                    TensorLayout.NCHW -> {
                        val o = y * n + x
                        out[o] = rf; out[plane + o] = gf; out[2 * plane + o] = bf
                    }
                }
            }
        }
        return out
    }
}

/**
 * 64-bit difference hash of a frame (9×8 grey grid, one bit per horizontal
 * gradient). Only used to skip re-classifying a screen that hasn't
 * changed; it's kept in memory and can't be turned back into an image.
 */
object FrameHash {
    fun dHash(frame: RgbaFrame): Long {
        val grey = IntArray(9 * 8)
        for (gy in 0 until 8) {
            val y = ((gy * 2 + 1) * frame.height / 16).coerceIn(0, frame.height - 1)
            for (gx in 0 until 9) {
                val x = ((gx * 2 + 1) * frame.width / 18).coerceIn(0, frame.width - 1)
                grey[gy * 9 + gx] = (frame.r(x, y) * 299 + frame.g(x, y) * 587 + frame.b(x, y) * 114) / 1000
            }
        }
        var h = 0L
        for (gy in 0 until 8) for (gx in 0 until 8) {
            if (grey[gy * 9 + gx] > grey[gy * 9 + gx + 1]) h = h or (1L shl (gy * 8 + gx))
        }
        return h
    }

    /** 64-bit FNV-1a of already-extracted text (in memory only). */
    fun text(s: String): Long {
        var h = -0x340d631b7bdddcdbL
        for (ch in s) {
            h = h xor ch.code.toLong()
            h *= 0x100000001b3L
        }
        return h
    }

    fun distance(a: Long, b: Long) = java.lang.Long.bitCount(a xor b)
}

/**
 * Decides *when* to classify, so the shield never runs continuously:
 *
 * - at most one sample per [minIntervalMs];
 * - while the screen keeps changing (scrolling), wait until it has been
 *   still for [settleMs], but never longer than [maxWaitMs] between samples;
 * - skip a screen whose hash is within [sameScreenBits] of the last sampled
 *   one, unless the last result still needs confirmation;
 * - never sample while [active] is false (protection off, app not
 *   supported, screen off).
 */
class FrameGate(
    private val minIntervalMs: Long = 800,
    private val settleMs: Long = 300,
    private val maxWaitMs: Long = 2_000,
    private val sameScreenBits: Int = 4,
) {
    private var lastSampleAt = Long.MIN_VALUE / 2
    private var lastChangeAt = Long.MIN_VALUE / 2
    private var firstPendingChangeAt: Long? = null
    private var lastHash: Long? = null
    private var needsConfirmation = false

    @Synchronized
    fun onContentChanged(now: Long) {
        lastChangeAt = now
        if (firstPendingChangeAt == null) firstPendingChangeAt = now
    }

    /** Call when the foreground app changes or the shield pauses. */
    @Synchronized
    fun reset() {
        lastHash = null
        needsConfirmation = false
        firstPendingChangeAt = null
    }

    @Synchronized
    fun shouldSample(now: Long, hash: Long?, active: Boolean): Boolean {
        if (!active) return false
        if (now - lastSampleAt < minIntervalMs) return false
        val settling = now - lastChangeAt < settleMs
        val waitedTooLong = firstPendingChangeAt?.let { now - it >= maxWaitMs } ?: false
        if (settling && !waitedTooLong) return false
        if (hash != null && !needsConfirmation) {
            val last = lastHash
            if (last != null && FrameHash.distance(last, hash) <= sameScreenBits) return false
        }
        lastSampleAt = now
        lastHash = hash
        firstPendingChangeAt = null
        return true
    }

    /** The last sample's decision was pending confirmation (UNCERTAIN). */
    @Synchronized
    fun onResult(pending: Boolean) {
        needsConfirmation = pending
    }
}
