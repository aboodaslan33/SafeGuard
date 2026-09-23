package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ClassificationStatus
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.DecisionPolicy
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.ai.image.ModelInputSpec
import com.safeguard.app.engine.explain.DecisionExplainer
import com.safeguard.app.engine.explain.Explanation
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.ByteBuffer

class ContentShieldTest {

    // ---- helpers -----------------------------------------------------------

    private var now = 1_000_000L
    private val instagram = "com.instagram.android"

    private fun frame(w: Int, h: Int, rowPad: Int = 0, pixel: (Int, Int) -> Int): RgbaFrame {
        val stride = w * 4 + rowPad
        val buf = ByteBuffer.allocate(stride * h)
        for (y in 0 until h) for (x in 0 until w) {
            val p = pixel(x, y)
            val o = y * stride + x * 4
            buf.put(o, (p shr 16).toByte()); buf.put(o + 1, (p shr 8).toByte()); buf.put(o + 2, p.toByte()); buf.put(o + 3, 0xFF.toByte())
        }
        return RgbaFrame(w, h, buf, stride)
    }

    private val pack = ImageModelPack.parse(
        """
        format=sg-image-pack/1
        id=test-pack
        version=3
        runtime=onnx
        sizeBytes=4
        sha256=${sha("abcd".toByteArray())}
        inputSize=32
        layout=nchw
        mean=0.5,0.5,0.5
        std=0.5,0.5,0.5
        output=logits
        labels=safe,suggestive,sexual,nudity,violence
        minConfidence=0.5
        license=Test fixture (no weights)
        provenance=Unit test
        """.trimIndent(),
    )

    private fun sha(b: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** Test double for an inference runtime: returns fixed outputs. Not AI. */
    private class FixedRuntime(var out: FloatArray) : ImageInferenceRuntime {
        var closed = false
        var lastInput: FloatArray? = null
        var runs = 0
        override fun run(input: FloatArray): FloatArray {
            runs++
            lastInput = input.copyOf()
            return out
        }
        override fun close() { closed = true }
    }

    private fun policy(mode: DetectionMode = DetectionMode.NORMAL, ai: Boolean = true) =
        DecisionPolicy(true, Category.filterable.toSet(), AiSettings(enabled = ai, mode = mode))

    private class Harness(
        val text: (String) -> ClassificationResult,
        var settings: ShieldSettings = ShieldSettings(enabled = true),
        var protection: Boolean = true,
        var mode: DetectionMode = DetectionMode.NORMAL,
        var aiOn: Boolean = true,
        image: ShieldImageClassifier = ShieldImageClassifier(null, { null }, { null }),
        clock: () -> Long,
    ) {
        var calls = 0
        val engine = ContentShieldEngine(
            classifyText = { calls++; text(it) },
            image = image,
            policy = { DecisionPolicy(true, Category.filterable.toSet(), AiSettings(enabled = aiOn, mode = mode)) },
            settings = { settings },
            protectionActive = { protection },
            clock = clock,
        )
    }

    private fun textResult(c: Category, s: Double) = ClassificationResult(ClassificationStatus.OK, mapOf(c to s, Category.SAFE to 1 - s), "sg-text-1")

    // ---- engine --------------------------------------------------------------

    @Test fun nothingIsInspectedWhenProtectionShieldAiOrAppIsOff() {
        val h = Harness({ textResult(Category.SEXUAL, 0.99) }, clock = { now })
        h.protection = false
        assertEquals(ShieldOutcome.Skipped, h.engine.onText(instagram, "some caption"))
        h.protection = true; h.settings = ShieldSettings(enabled = false)
        assertEquals(ShieldOutcome.Skipped, h.engine.onText(instagram, "some caption"))
        h.settings = ShieldSettings(enabled = true, disabledApps = setOf("instagram"))
        assertEquals(ShieldOutcome.Skipped, h.engine.onText(instagram, "some caption"))
        h.settings = ShieldSettings(enabled = true); h.aiOn = false
        assertEquals(ShieldOutcome.Skipped, h.engine.onText(instagram, "some caption"))
        h.aiOn = true
        // Unsupported app: never inspected.
        assertEquals(ShieldOutcome.Skipped, h.engine.onText("com.whatsapp", "some caption"))
        assertFalse(h.engine.isActiveFor("com.whatsapp"))
        assertEquals("the classifier must not even run", 0, h.calls)
    }

    @Test fun highConfidenceTextBlocksWithMetadataOnly() {
        val h = Harness({ textResult(Category.GAMBLING, 0.99) }, clock = { now })
        val out = h.engine.onText(instagram, "secret caption text 123")
        assertTrue(out is ShieldOutcome.Blocked)
        val e = (out as ShieldOutcome.Blocked).event
        assertEquals(instagram, e.packageName)
        assertEquals(Category.GAMBLING, e.category)
        assertEquals(AiLabel.GAMBLING, e.label)
        assertEquals(90, e.confidenceBucket)
        assertEquals("sg-text-1", e.modelVersion)
        assertEquals("ai_shield:text:gambling:sg-text-1", e.ruleType)
        assertFalse("event never contains the text", e.toString().contains("secret"))
        assertEquals(Explanation.AI_CONTENT_SHIELD, DecisionExplainer.event(EventSource.AI, e.ruleType))
    }

    @Test fun uncertainTextNeedsConfirmationAndUnchangedTextIsNotReclassified() {
        var score = 0.93
        val h = Harness({ textResult(Category.SEXUAL, score) }, clock = { now })
        assertTrue(h.engine.onText(instagram, "caption a") is ShieldOutcome.Pending)
        now += 1500
        assertTrue(h.engine.onText(instagram, "caption a") is ShieldOutcome.Blocked) // confirmation sample
        // After a block the streak restarts; a second block within the
        // cooldown is suppressed (the user was just sent home).
        now += 500
        assertTrue(h.engine.onText(instagram, "caption b") is ShieldOutcome.Pending)
        now += 500
        assertEquals(ShieldOutcome.Skipped, h.engine.onText(instagram, "caption b"))
        // Same, settled text: not classified again.
        score = 0.1
        now += 10_000
        assertTrue(h.engine.onText(instagram, "caption c") is ShieldOutcome.Allowed)
        val calls = h.calls
        assertEquals(ShieldOutcome.Skipped, h.engine.onText(instagram, "caption c"))
        assertEquals(calls, h.calls)
    }

    @Test fun switchingAppsDropsEvidence() {
        val h = Harness({ textResult(Category.VIOLENCE, 0.93) }, clock = { now })
        h.engine.onForeground(instagram)
        assertTrue(h.engine.onText(instagram, "x caption") is ShieldOutcome.Pending)
        h.engine.onForeground("com.android.chrome")
        now += 1000
        assertTrue("evidence from Instagram doesn't confirm Chrome", h.engine.onText("com.android.chrome", "x caption") is ShieldOutcome.Pending)
    }

    @Test fun classifierFailureIsNeverABlock() {
        val h = Harness({ throw IllegalStateException("boom") }, clock = { now })
        val out = h.engine.onText(instagram, "caption")
        assertTrue(out is ShieldOutcome.Allowed)
        assertEquals("UNKNOWN, not BLOCK", com.safeguard.app.engine.ai.FinalAction.UNKNOWN, (out as ShieldOutcome.Allowed).decision.decision.action)
        val oom = Harness({ throw OutOfMemoryError() }, clock = { now })
        assertTrue(oom.engine.onText(instagram, "caption") is ShieldOutcome.Allowed)
    }

    @Test fun slowInferencePausesTheShieldInsteadOfLooping() {
        var t = 0L
        val h = Harness({ t += 400; textResult(Category.SEXUAL, 0.1) }, clock = { now + t })
        repeat(3) { i -> h.engine.onText(instagram, "caption $i") }
        assertTrue(h.engine.textSlow)
        assertFalse(h.engine.wantsText(instagram))
        t += 61_000
        assertFalse(h.engine.textSlow)
    }

    @Test fun imageWithoutAModelIsSkippedAndReportsNotBundled() {
        val h = Harness({ textResult(Category.SAFE, 0.0) }, clock = { now })
        assertEquals(ShieldOutcome.Skipped, h.engine.onFrame(instagram, frame(16, 16) { _, _ -> 0 }))
        val c = ShieldImageClassifier(BuiltInImagePacks.all.firstOrNull(), { null }, { null })
        assertEquals(ImageModelState.NOT_BUNDLED, c.state)
        assertFalse(c.isUsable)
        assertTrue("no image model ships in this version", BuiltInImagePacks.all.isEmpty())
    }

    @Test fun imagePipelineRunsThroughPolicyWithARuntime() {
        // Plumbing test with a fixed-output runtime (test double, not AI).
        val rt = FixedRuntime(floatArrayOf(0f, 0f, 6f, 0f, 0f)) // logits → "sexual" ≈ 0.95
        val image = ShieldImageClassifier(pack, { "abcd".toByteArray() }, { ImageRuntimeFactory { _, _ -> rt } })
        val h = Harness({ textResult(Category.SAFE, 0.0) }, image = image, clock = { now })
        val out = h.engine.onFrame(instagram, frame(64, 64) { x, _ -> if (x < 32) 0xFF0000 else 0x0000FF })
        assertTrue(out.toString(), out is ShieldOutcome.Blocked)
        val e = (out as ShieldOutcome.Blocked).event
        assertEquals(ContentKind.IMAGE, e.kind)
        assertEquals(AiLabel.SEXUAL, e.label)
        assertEquals("test-pack@3", e.modelVersion)
        // The same frame again isn't re-run (same-screen skip), and the tensor was cleared after use.
        now += 5_000
        assertEquals(ShieldOutcome.Skipped, h.engine.onFrame(instagram, frame(64, 64) { x, _ -> if (x < 32) 0xFF0000 else 0x0000FF }))
        assertEquals(1, rt.runs)
        h.engine.release()
        assertTrue("model released when the shield stops", rt.closed)
        assertEquals(ImageModelState.NOT_LOADED, image.state)
    }

    // ---- image classifier failures -------------------------------------------

    @Test fun corruptedMissingOrUnloadableModelsAreRejected() {
        val wrong = ShieldImageClassifier(pack, { "abce".toByteArray() }, { ImageRuntimeFactory { _, _ -> FixedRuntime(FloatArray(5)) } })
        assertEquals(AiLabel.UNKNOWN, wrong.classify(frame(8, 8) { _, _ -> 0 }).label)
        assertEquals(ImageModelState.CORRUPTED, wrong.state)
        val missing = ShieldImageClassifier(pack, { null }, { ImageRuntimeFactory { _, _ -> FixedRuntime(FloatArray(5)) } })
        missing.classify(frame(8, 8) { _, _ -> 0 })
        assertEquals(ImageModelState.CORRUPTED, missing.state)
        val noRuntime = ShieldImageClassifier(pack, { "abcd".toByteArray() }, { null })
        noRuntime.classify(frame(8, 8) { _, _ -> 0 })
        assertEquals(ImageModelState.NO_RUNTIME, noRuntime.state)
        val fails = ShieldImageClassifier(pack, { "abcd".toByteArray() }, { ImageRuntimeFactory { _, _ -> throw IllegalArgumentException("bad model") } })
        fails.classify(frame(8, 8) { _, _ -> 0 })
        assertEquals(ImageModelState.LOAD_FAILED, fails.state)
        fails.resetAfterFailure()
        assertEquals(ImageModelState.NOT_LOADED, fails.state)
        val oomLoad = ShieldImageClassifier(pack, { "abcd".toByteArray() }, { ImageRuntimeFactory { _, _ -> throw OutOfMemoryError() } })
        oomLoad.classify(frame(8, 8) { _, _ -> 0 })
        assertEquals(ImageModelState.OUT_OF_MEMORY, oomLoad.state)
    }

    @Test fun outOfMemoryDuringInferenceReleasesTheModel() {
        val rt = object : ImageInferenceRuntime {
            var closed = false
            override fun run(input: FloatArray): FloatArray = throw OutOfMemoryError()
            override fun close() { closed = true }
        }
        val c = ShieldImageClassifier(pack, { "abcd".toByteArray() }, { ImageRuntimeFactory { _, _ -> rt } })
        assertEquals(AiLabel.UNKNOWN, c.classify(frame(8, 8) { _, _ -> 0 }).label)
        assertTrue(rt.closed)
        assertEquals(ImageModelState.OUT_OF_MEMORY, c.state)
    }

    @Test fun badModelOutputsAreUnavailableNotGuessed() {
        val softmaxPack = pack.copy(output = OutputKind.SOFTMAX)
        assertNull(ShieldImageClassifier.probabilities(floatArrayOf(0.5f, 0.5f), softmaxPack)) // wrong size
        assertNull(ShieldImageClassifier.probabilities(floatArrayOf(Float.NaN, 0f, 0f, 0f, 1f), softmaxPack))
        assertNull(ShieldImageClassifier.probabilities(floatArrayOf(0.9f, 0.9f, 0f, 0f, 0f), softmaxPack)) // sum 1.8
        assertNull(ShieldImageClassifier.probabilities(floatArrayOf(-0.5f, 1.5f, 0f, 0f, 0f), softmaxPack))
        val p = ShieldImageClassifier.probabilities(floatArrayOf(1f, 1f, 1f, 1f, 1f), pack)!! // logits
        assertEquals(1.0, p.sum(), 1e-9)
        assertEquals(0.2, p[0], 1e-9)
    }

    // ---- packs -----------------------------------------------------------------

    @Test fun packManifestIsStrict() {
        assertEquals("test-pack@3", pack.modelVersion)
        assertEquals(listOf(AiLabel.SAFE, AiLabel.SUGGESTIVE, AiLabel.SEXUAL, AiLabel.NUDITY, AiLabel.VIOLENCE), pack.labels)
        val good = """
            format=sg-image-pack/1
            id=a
            version=1
            runtime=tflite
            sizeBytes=10
            sha256=${"0".repeat(64)}
            inputSize=224
            layout=nhwc
            mean=0,0,0
            std=1,1,1
            output=softmax
            labels=safe,sexual
            minConfidence=0.5
            license=x
            provenance=y
        """.trimIndent()
        ImageModelPack.parse(good)
        val bad = listOf(
            good.replace("format=sg-image-pack/1", "format=sg-image-pack/2"),
            good.replace("runtime=tflite", "runtime=dex"),
            good.replace("labels=safe,sexual", "labels=safe,porn"),
            good.replace("labels=safe,sexual", "labels=safe,safe"),
            good.replace("labels=safe,sexual", "labels=safe,unknown"),
            good.replace("sizeBytes=10", "sizeBytes=999999999"),
            good.replace("inputSize=224", "inputSize=5000"),
            good.replace("std=1,1,1", "std=0,1,1"),
            good.replace("sha256=${"0".repeat(64)}", "sha256=xyz"),
            good + "\nextra=1",
            good + "\nid=b",
            good.lines().filterNot { it.startsWith("license") }.joinToString("\n"),
            "x".repeat(5000),
        )
        for (b in bad) {
            try {
                ImageModelPack.parse(b)
                fail("accepted: ${b.take(60)}")
            } catch (e: IllegalArgumentException) {
                // expected (require/error both throw IllegalArgumentException / IllegalStateException)
            } catch (e: IllegalStateException) {
            }
        }
    }

    // ---- frames ------------------------------------------------------------------

    @Test fun preprocessorHonoursLayoutStrideAndNormalisation() {
        val f = frame(4, 2, rowPad = 12) { x, _ -> if (x < 2) 0xFF0000 else 0x00FF00 }
        val spec = ModelInputSpec(2, floatArrayOf(0f, 0f, 0f), floatArrayOf(1f, 1f, 1f))
        val nhwc = FramePreprocessor.toTensor(f, spec, TensorLayout.NHWC, FloatArray(12))
        assertEquals(listOf(1f, 0f, 0f, 0f, 1f, 0f), nhwc.take(6))
        val nchw = FramePreprocessor.toTensor(f, spec, TensorLayout.NCHW, FloatArray(12))
        // R plane: [1, 0, 1, 0]; G plane: [0, 1, 0, 1]
        assertEquals(listOf(1f, 0f, 1f, 0f, 0f, 1f, 0f, 1f), nchw.take(8))
    }

    @Test fun framesAreBoundedAndValidated() {
        try {
            RgbaFrame(10, 10, ByteBuffer.allocate(10), 40)
            fail("buffer too small accepted")
        } catch (e: IllegalArgumentException) {
        }
        try {
            RgbaFrame(RgbaFrame.MAX_SIDE + 1, 1, ByteBuffer.allocate(1), 4 * (RgbaFrame.MAX_SIDE + 1))
            fail("oversized frame accepted")
        } catch (e: IllegalArgumentException) {
        }
        assertFalse(frame(4, 4) { _, _ -> 0 }.toString().contains("0x"))
    }

    @Test fun hashSeparatesDifferentScreensAndMatchesSameScreen() {
        val a = frame(90, 80) { x, y -> if ((x / 10 + y / 10) % 2 == 0) 0xFFFFFF else 0 }
        val a2 = frame(90, 80) { x, y -> if ((x / 10 + y / 10) % 2 == 0) 0xFFFFFF else 0 }
        val b = frame(90, 80) { x, _ -> x * 255 / 90 * 0x010101 }
        assertEquals(FrameHash.dHash(a), FrameHash.dHash(a2))
        assertTrue(FrameHash.distance(FrameHash.dHash(a), FrameHash.dHash(b)) > 10)
        assertNotEquals(FrameHash.text("a"), FrameHash.text("b"))
    }

    @Test fun gateThrottlesDebouncesAndSkipsSameScreen() {
        val g = FrameGate(minIntervalMs = 800, settleMs = 300, maxWaitMs = 2000, sameScreenBits = 4)
        assertFalse("inactive never samples", g.shouldSample(0, 1L, active = false))
        assertTrue(g.shouldSample(0, 1L, true))
        assertFalse("throttled", g.shouldSample(500, 999L, true))
        g.onContentChanged(900)
        assertFalse("still scrolling", g.shouldSample(1000, 999L, true))
        assertTrue("settled", g.shouldSample(1300, 0xFFFFL, true))
        assertFalse("same screen", g.shouldSample(3000, 0xFFFFL, true))
        g.onResult(pending = true)
        assertTrue("same screen re-sampled to confirm", g.shouldSample(4000, 0xFFFFL, true))
        g.onResult(pending = false)
        // Continuous scrolling still samples every maxWait.
        for (t in 5000L..8000L step 100) g.onContentChanged(t)
        var sampled = 0
        for (t in 5000L..8000L step 100) {
            g.onContentChanged(t)
            if (g.shouldSample(t, t, true)) sampled++
        }
        assertTrue("sampled $sampled", sampled in 1..2)
    }

    // ---- visible text --------------------------------------------------------------

    private data class Node(
        val text: String? = null,
        val desc: String? = null,
        val editable: Boolean = false,
        val password: Boolean = false,
        val visible: Boolean = true,
        val children: List<Node> = emptyList(),
    )

    private class Tree : NodeView<Node> {
        var released = 0
        var obtained = 0
        override fun childCount(n: Node) = n.children.size
        override fun child(n: Node, i: Int) = n.children[i].also { obtained++ }
        override fun text(n: Node) = n.text
        override fun description(n: Node) = n.desc
        override fun isEditable(n: Node) = n.editable
        override fun isPassword(n: Node) = n.password
        override fun isVisible(n: Node) = n.visible
        override fun release(n: Node) { released++ }
    }

    @Test fun visibleTextSkipsInputsSecretsAndInvisibleContent() {
        val root = Node(
            children = listOf(
                Node("Great goal in the final minute"),
                Node("typed message", editable = true, children = listOf(Node("child of input"))),
                Node("hunter2", password = true),
                Node("hidden caption", visible = false),
                Node("Your code is 482913"),
                Node("4111 1111 1111 1111"),
                Node("mail me at someone@example.com"),
                Node("see https://example.com/page"),
                Node(desc = "Photo of a beach"),
                Node("Great goal in the final minute"), // duplicate
            ),
        )
        val tree = Tree()
        val text = VisibleTextExtractor.extract(root, tree)
        assertEquals("Great goal in the final minute\nPhoto of a beach", text)
        assertEquals("every obtained child is released", tree.obtained, tree.released)
    }

    @Test fun visibleTextIsBounded() {
        val wide = Node(children = List(1000) { Node("caption number x$it words here") })
        val t = VisibleTextExtractor.extract(wide, Tree(), VisibleTextExtractor.Limits(maxNodes = 50, maxChars = 10_000))
        assertTrue(t.lines().size < 50)
        val long = Node(children = List(100) { Node("word ".repeat(100) + it) })
        assertTrue(VisibleTextExtractor.extract(long, Tree()).length <= 2_000)
        var deep = Node("bottom")
        repeat(100) { deep = Node(children = listOf(deep)) }
        assertEquals("", VisibleTextExtractor.extract(deep, Tree()))
    }

    // ---- status, apps, settings -------------------------------------------------------

    @Test fun statusNeverClaimsMoreThanIsRunning() {
        val on = ShieldSettings(enabled = true)
        fun r(
            s: ShieldSettings = on, protection: Boolean = true, ai: Boolean = true, a11y: Boolean = true,
            a11yAvail: Boolean = true, text: Boolean = true, image: Boolean = false,
        ) = ShieldStatusResolver.resolve(s, protection, ai, a11y, a11yAvail, text, image)
        assertEquals(ShieldState.OFF, r(s = ShieldSettings()).state)
        // Shipped state: text model only.
        val shipped = r()
        assertEquals(ShieldState.PARTIAL, shipped.state)
        assertEquals(listOf(ShieldIssue.IMAGE_MODEL_UNAVAILABLE), shipped.issues)
        assertTrue(shipped.textActive); assertFalse(shipped.imageActive)
        assertEquals(ShieldState.ACTIVE, r(image = true).state)
        for (bad in listOf(r(protection = false), r(ai = false), r(a11y = false), r(a11yAvail = false), r(text = false), r(s = on.copy(disabledApps = SupportedApps.all.map { it.key }.toSet())))) {
            assertEquals(bad.issues.toString(), ShieldState.UNAVAILABLE, bad.state)
            assertFalse(bad.textActive || bad.imageActive)
        }
        assertEquals(listOf(ShieldIssue.ACCESSIBILITY_UNAVAILABLE), r(a11yAvail = false, a11y = false).issues.take(1))
        val slow = ShieldStatusResolver.resolve(on, true, true, true, true, true, false, textSlow = true)
        assertEquals(ShieldState.UNAVAILABLE, slow.state)
        assertTrue(ShieldIssue.INFERENCE_SLOW in slow.issues)
    }

    @Test fun supportedAppsCoverTheRequiredAppsWithoutHardcodingOne() {
        val keys = SupportedApps.all.map { it.key }
        assertEquals(listOf("instagram", "tiktok", "youtube", "reddit", "chrome", "firefox"), keys)
        assertEquals("tiktok", SupportedApps.forPackage("com.ss.android.ugc.trill")?.key)
        assertNull(SupportedApps.forPackage("com.whatsapp"))
        assertTrue("nothing is verified on a device yet", SupportedApps.all.none { it.verifiedOnDevice })
        assertTrue(SupportedApps.all.all { ShieldLimitation.IMAGES_NEED_MODEL in it.limitations })
        assertEquals(emptyList<String>(), ShieldSettings(enabled = false).monitoredPackages())
        val some = ShieldSettings(enabled = true, disabledApps = setOf("tiktok"))
        assertFalse("com.zhiliaoapp.musically" in some.monitoredPackages())
        assertTrue("com.android.chrome" in some.monitoredPackages())
    }

    @Test fun looseningShieldSettingsIsDetectedForThePin() {
        val on = ShieldSettings(enabled = true)
        assertTrue(on.isLoosenedBy(ShieldSettings(enabled = false)))
        assertTrue(on.isLoosenedBy(on.copy(disabledApps = setOf("reddit"))))
        assertFalse(on.copy(disabledApps = setOf("reddit")).isLoosenedBy(on))
        assertFalse(ShieldSettings().isLoosenedBy(on))
    }

    @Test fun confidenceBucketsAreCoarse() {
        assertEquals(90, confidenceBucket(0.96))
        assertEquals(0, confidenceBucket(Double.NaN))
        assertEquals(100, confidenceBucket(1.0))
    }
}
