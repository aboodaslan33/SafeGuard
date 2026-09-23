package com.safeguard.app.engine.ai

import com.safeguard.app.engine.ai.image.DecodedImage
import com.safeguard.app.engine.ai.image.ImageDecoder
import com.safeguard.app.engine.ai.image.ImageFormat
import com.safeguard.app.engine.ai.image.ImageHeaderParser
import com.safeguard.app.engine.ai.image.ImageLimits
import com.safeguard.app.engine.ai.image.ImageModelRuntime
import com.safeguard.app.engine.ai.image.ImagePreprocessor
import com.safeguard.app.engine.ai.image.ImageRejectedException
import com.safeguard.app.engine.ai.image.LocalImageClassifierAdapter
import com.safeguard.app.engine.ai.image.ModelInputSpec
import com.safeguard.app.engine.ai.video.SamplingPlan
import com.safeguard.app.engine.ai.video.VideoFrameSource
import com.safeguard.app.engine.ai.video.VideoSampler
import com.safeguard.app.engine.rules.Category
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Minimal valid headers built byte by byte (no image files needed). */
object TestImages {
    fun png(w: Int, h: Int): ByteArray {
        val b = ByteArray(33)
        intArrayOf(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A).forEachIndexed { i, v -> b[i] = v.toByte() }
        be32(b, 8, 13)
        "IHDR".forEachIndexed { i, c -> b[12 + i] = c.code.toByte() }
        be32(b, 16, w)
        be32(b, 20, h)
        return b
    }

    fun jpeg(w: Int, h: Int): ByteArray = byteArrayOf(
        0xFF.toByte(), 0xD8.toByte(),
        // APP0 segment (length 16) to exercise marker skipping.
        0xFF.toByte(), 0xE0.toByte(), 0, 16, *ByteArray(14),
        // SOF0: length 11, precision 8, height, width, 1 component.
        0xFF.toByte(), 0xC0.toByte(), 0, 11, 8,
        (h shr 8).toByte(), h.toByte(), (w shr 8).toByte(), w.toByte(), 1, 1, 0x11, 0,
        0xFF.toByte(), 0xD9.toByte(),
    )

    fun webpVp8x(w: Int, h: Int): ByteArray {
        val b = ByteArray(30)
        "RIFF".forEachIndexed { i, c -> b[i] = c.code.toByte() }
        "WEBP".forEachIndexed { i, c -> b[8 + i] = c.code.toByte() }
        "VP8X".forEachIndexed { i, c -> b[12 + i] = c.code.toByte() }
        le24(b, 24, w - 1)
        le24(b, 27, h - 1)
        return b
    }

    private fun be32(b: ByteArray, i: Int, v: Int) {
        b[i] = (v ushr 24).toByte(); b[i + 1] = (v ushr 16).toByte(); b[i + 2] = (v ushr 8).toByte(); b[i + 3] = v.toByte()
    }

    private fun le24(b: ByteArray, i: Int, v: Int) {
        b[i] = v.toByte(); b[i + 1] = (v ushr 8).toByte(); b[i + 2] = (v ushr 16).toByte()
    }
}

/** Decoder that produces a solid-colour image and records every close. */
class FakeDecoder(private val argb: Int = 0xFFFF0000.toInt(), private val fail: Boolean = false) : ImageDecoder {
    val opened = ArrayList<FakeImage>()
    var lastSample = 0

    class FakeImage(override val width: Int, override val height: Int, colour: Int) : DecodedImage {
        override val pixels = IntArray(width * height) { colour }
        var closed = false
        override fun close() {
            pixels.fill(0)
            closed = true
        }
    }

    override fun decode(bytes: ByteArray, header: com.safeguard.app.engine.ai.image.ImageHeader, sampleSize: Int): DecodedImage {
        if (fail) throw IllegalStateException("corrupt stream")
        lastSample = sampleSize
        val img = FakeImage(header.width / sampleSize, header.height / sampleSize, argb)
        opened += img
        return img
    }
}

class FakeRuntime(
    private val output: FloatArray = floatArrayOf(0.97f, 0.01f, 0.0f),
    private val throwOnRun: Boolean = false,
) : ImageModelRuntime {
    override val modelId = "fake-image"
    override val input = ModelInputSpec(size = 8)
    override val labels = listOf(Category.SEXUAL, Category.VIOLENCE, Category.GORE)
    var lastTensor: FloatArray? = null
    var closed = false

    override fun run(tensor: FloatArray): FloatArray {
        lastTensor = tensor
        if (throwOnRun) throw IllegalStateException("inference failed")
        return output
    }

    override fun close() {
        closed = true
    }
}

class ImagePipelineTest {
    private fun adapter(decoder: ImageDecoder = FakeDecoder(), runtime: ImageModelRuntime? = FakeRuntime(), limits: ImageLimits = ImageLimits()) =
        LocalImageClassifierAdapter("local-image", decoder, { runtime }, limits)

    private fun classify(bytes: ByteArray, a: LocalImageClassifierAdapter = adapter(), mime: String? = null) =
        a.classify(ContentInput.Image(bytes, mime))

    // ---- validation ------------------------------------------------------

    @Test fun formatsAreSniffedFromBytes() {
        assertEquals(ImageFormat.PNG, ImageHeaderParser.parse(TestImages.png(640, 480)).format)
        val jpeg = ImageHeaderParser.parse(TestImages.jpeg(1920, 1080))
        assertEquals(ImageFormat.JPEG, jpeg.format)
        assertEquals(1920 to 1080, jpeg.width to jpeg.height)
        val webp = ImageHeaderParser.parse(TestImages.webpVp8x(300, 200))
        assertEquals(ImageFormat.WEBP to (300 to 200), webp.format to (webp.width to webp.height))
    }

    @Test fun unsupportedFilesAreRejected() {
        val gif = "GIF89a".toByteArray() + ByteArray(20)
        val bmp = "BM".toByteArray() + ByteArray(40)
        val pdf = "%PDF-1.7".toByteArray()
        val script = "#!/bin/sh\nrm -rf /".toByteArray()
        for (b in listOf(gif, bmp, pdf, script)) {
            assertEquals(ClassificationError.UNSUPPORTED_TYPE, classify(b).error)
        }
    }

    @Test fun emptyInputIsRejected() {
        assertEquals(ClassificationError.EMPTY_INPUT, classify(ByteArray(0)).error)
    }

    @Test fun declaredTypeMustMatchContent() {
        assertEquals(ClassificationError.TYPE_MISMATCH, classify(TestImages.png(10, 10), mime = "image/jpeg").error)
        assertEquals(ClassificationStatus.OK, classify(TestImages.jpeg(10, 10), mime = "image/jpg").status)
        assertEquals(ClassificationStatus.OK, classify(TestImages.png(10, 10), mime = null).status)
    }

    @Test fun malformedFilesAreRejected() {
        assertEquals(ClassificationError.MALFORMED, classify(TestImages.png(640, 480).copyOf(20)).error)
        assertEquals(ClassificationError.MALFORMED, classify(TestImages.png(0, 480)).error)
        assertEquals(ClassificationError.MALFORMED, classify(TestImages.png(-5, 480)).error)
        // JPEG with a segment length running past the end.
        val badJpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x7F, 0x7F, 1, 2, 3)
        assertEquals(ClassificationError.MALFORMED, classify(badJpeg).error)
        // JPEG that reaches start-of-scan without a frame header.
        val noSof = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xDA.toByte(), 0, 2)
        assertEquals(ClassificationError.MALFORMED, classify(noSof).error)
        // Random bytes after a JPEG magic.
        val junk = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte()) + ByteArray(64) { (it * 37).toByte() }
        assertEquals(ClassificationStatus.REJECTED, classify(junk).status)
    }

    @Test fun jpegParserTerminatesOnPathologicalInput() {
        // Thousands of fill bytes: must finish quickly and reject.
        val fill = byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + ByteArray(100_000) { 0xFF.toByte() }
        assertEquals(ClassificationStatus.REJECTED, classify(fill).status)
    }

    @Test fun largeFilesAreRejectedBeforeDecoding() {
        val decoder = FakeDecoder()
        val big = TestImages.png(100, 100) + ByteArray(2_000_000)
        val r = classify(big, adapter(decoder, limits = ImageLimits(maxBytes = 1_000_000)))
        assertEquals(ClassificationError.FILE_TOO_LARGE, r.error)
        assertTrue(decoder.opened.isEmpty())
    }

    @Test fun hugeDimensionsAreRejectedBeforeDecoding() {
        val decoder = FakeDecoder()
        assertEquals(ClassificationError.DIMENSIONS_TOO_LARGE, classify(TestImages.png(20_000, 100), adapter(decoder)).error)
        assertEquals(ClassificationError.DIMENSIONS_TOO_LARGE, classify(TestImages.png(10_000, 10_000), adapter(decoder)).error)
        // Decompression bomb: tiny file, 16k × 16k pixels.
        assertEquals(ClassificationError.DIMENSIONS_TOO_LARGE, classify(TestImages.png(16_000, 16_000), adapter(decoder)).error)
        assertTrue(decoder.opened.isEmpty())
    }

    @Test fun largeImagesAreSubsampledWithinMemoryBudget() {
        val decoder = FakeDecoder()
        val r = classify(TestImages.jpeg(4000, 3000), adapter(decoder))
        assertEquals(ClassificationStatus.OK, r.status)
        // Model input is 8 px: 4000×3000 is sampled by 256 → ~15×11 decoded.
        assertEquals(256, decoder.lastSample)
        assertTrue(decoder.opened.single().pixels.size < 400)
        assertEquals(1, ImagePreprocessor.sampleSize(300, 300, 224))
        assertEquals(8, ImagePreprocessor.sampleSize(4000, 3000, 224))
        assertTrue(ImagePreprocessor.decodedBytes(com.safeguard.app.engine.ai.image.ImageHeader(ImageFormat.JPEG, 4000, 3000), 8) < 16L * 1024 * 1024)
    }

    @Test fun decodedBudgetIsEnforced() {
        val decoder = FakeDecoder()
        val tight = ImageLimits(maxDecodedBytes = 100)
        assertEquals(ClassificationError.DIMENSIONS_TOO_LARGE, classify(TestImages.png(200, 200), adapter(decoder, limits = tight)).error)
        assertTrue(decoder.opened.isEmpty())
    }

    // ---- inference + cleanup ------------------------------------------------

    @Test fun imageIsClassifiedMultiLabel() {
        val r = classify(TestImages.png(64, 64))
        assertEquals(ClassificationStatus.OK, r.status)
        assertEquals(0.97, r.score(Category.SEXUAL), 1e-6)
        assertEquals("fake-image", r.modelId)
        assertTrue(r.score(Category.SAFE) < 0.05)
    }

    @Test fun memoryIsReleasedAfterSuccess() {
        val decoder = FakeDecoder()
        val runtime = FakeRuntime()
        classify(TestImages.png(64, 64), adapter(decoder, runtime))
        val img = decoder.opened.single()
        assertTrue(img.closed)
        assertTrue(img.pixels.all { it == 0 })
        assertTrue("tensor cleared", runtime.lastTensor!!.all { it == 0f })
    }

    @Test fun memoryIsReleasedWhenInferenceFails() {
        val decoder = FakeDecoder()
        val runtime = FakeRuntime(throwOnRun = true)
        try {
            classify(TestImages.png(64, 64), adapter(decoder, runtime))
            fail()
        } catch (e: IllegalStateException) {
            // AdapterContentClassifier turns this into UNAVAILABLE (tested below).
        }
        assertTrue(decoder.opened.single().closed)
        assertTrue(runtime.lastTensor!!.all { it == 0f })
        val wrapped = AdapterContentClassifier(listOf(adapter(FakeDecoder(), FakeRuntime(throwOnRun = true))))
        assertEquals(ClassificationStatus.UNAVAILABLE, wrapped.classifyImage(TestImages.png(64, 64)).status)
    }

    @Test fun decoderFailureIsRejectedNotCrash() {
        assertEquals(ClassificationError.DECODE_FAILED, classify(TestImages.png(64, 64), adapter(FakeDecoder(fail = true))).error)
    }

    @Test fun badModelOutputIsUnavailable() {
        val nan = FakeRuntime(floatArrayOf(Float.NaN, 0f, 0f))
        assertEquals(ClassificationStatus.UNAVAILABLE, classify(TestImages.png(8, 8), adapter(runtime = nan)).status)
        val short = FakeRuntime(floatArrayOf(0.5f))
        assertEquals(ClassificationStatus.UNAVAILABLE, classify(TestImages.png(8, 8), adapter(runtime = short)).status)
    }

    @Test fun withoutModelTheAdapterSaysSoButStillValidates() {
        val a = adapter(runtime = null)
        assertFalse(a.isAvailable)
        assertEquals(ClassificationError.NO_MODEL, classify(TestImages.png(8, 8), a).error)
        assertEquals(ClassificationError.UNSUPPORTED_TYPE, classify("hello".toByteArray(), a).error)
    }

    @Test fun preprocessingResizesAndNormalises() {
        val img = FakeDecoder.FakeImage(40, 20, 0xFFFFFFFF.toInt()) // white
        val spec = ModelInputSpec(size = 4, mean = floatArrayOf(0.5f, 0.5f, 0.5f), std = floatArrayOf(0.5f, 0.5f, 0.5f))
        val t = ImagePreprocessor.toTensor(img, spec)
        assertEquals(4 * 4 * 3, t.size)
        assertTrue(t.all { kotlin.math.abs(it - 1f) < 1e-5 }) // (1 - 0.5) / 0.5
        val transparent = FakeDecoder.FakeImage(4, 4, 0x00000000) // composited on white
        assertTrue(ImagePreprocessor.toTensor(transparent, spec).all { kotlin.math.abs(it - 1f) < 1e-5 })
        val black = FakeDecoder.FakeImage(3, 3, 0xFF000000.toInt()) // upscaled
        assertTrue(ImagePreprocessor.toTensor(black, spec).all { kotlin.math.abs(it + 1f) < 1e-5 })
    }

    @Test fun rejectionExceptionCarriesError() {
        try {
            ImageHeaderParser.parse(ByteArray(3))
            fail()
        } catch (e: ImageRejectedException) {
            assertEquals(ClassificationError.UNSUPPORTED_TYPE, e.error)
        }
    }
}

class VideoSamplerTest {
    @Test fun planSamplesAtIntervalsWithCap() {
        val plan = SamplingPlan(intervalMs = 5_000, maxFrames = 4, startOffsetMs = 1_000)
        assertEquals(listOf(1_000L, 6_000L, 11_000L, 16_000L), plan.timestamps(600_000))
        assertEquals(listOf(1_000L), plan.timestamps(3_000))
        assertEquals(listOf(250L), plan.timestamps(500))
        assertTrue(plan.timestamps(0).isEmpty())
    }

    @Test fun invalidPlansAreRefused() {
        for (bad in listOf({ SamplingPlan(intervalMs = 10) }, { SamplingPlan(maxFrames = 0) }, { SamplingPlan(maxFrames = 1000) })) {
            try {
                bad()
                fail()
            } catch (e: IllegalArgumentException) {
                // expected
            }
        }
    }

    @Test fun samplerStopsEarlyAndClosesFrames() {
        val frames = ArrayList<FakeDecoder.FakeImage>()
        val source = VideoFrameSource { FakeDecoder.FakeImage(2, 2, 0).also { frames += it } }
        var n = 0
        val sampler = VideoSampler(SamplingPlan(maxFrames = 10)) {
            n++
            MockClassifierAdapter.result(Category.GORE to if (n == 3) 0.95 else 0.1)
        }
        val results = sampler.sample(120_000, source) { it.score(Category.GORE) > 0.9 }
        assertEquals(3, results.size)
        assertEquals(3, frames.size)
        assertTrue(frames.all { it.closed })
    }
}
