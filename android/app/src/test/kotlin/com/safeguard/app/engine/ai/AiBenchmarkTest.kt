package com.safeguard.app.engine.ai

import com.safeguard.app.engine.ai.image.ImagePreprocessor
import com.safeguard.app.engine.ai.image.ModelInputSpec
import com.safeguard.app.engine.ai.model.BuiltInModels
import com.safeguard.app.engine.ai.model.ModelLoader
import com.safeguard.app.engine.ai.text.TextFeatures
import com.safeguard.app.engine.ai.text.TextModel
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.lang.management.ManagementFactory

/**
 * Micro-benchmarks on the build machine's JVM (NOT an Android device).
 * Results go to build/ai-bench.txt and are copied, labelled as such, into
 * docs/PHASE_4_AI.md. Assertions are loose ceilings that only catch
 * pathological regressions.
 */
class AiBenchmarkTest {
    private val threads = ManagementFactory.getThreadMXBean()

    private fun medianMicros(runs: Int, block: () -> Unit): Pair<Double, Double> {
        repeat(runs / 5) { block() } // warm-up
        val wall = LongArray(runs)
        val cpuStart = threads.currentThreadCpuTime
        for (i in 0 until runs) {
            val t0 = System.nanoTime()
            block()
            wall[i] = System.nanoTime() - t0
        }
        val cpuPer = (threads.currentThreadCpuTime - cpuStart) / runs / 1000.0
        wall.sort()
        return wall[runs / 2] / 1000.0 to cpuPer
    }

    private fun usedHeap(): Long {
        val rt = Runtime.getRuntime()
        repeat(3) { System.gc(); Thread.sleep(20) }
        return rt.totalMemory() - rt.freeMemory()
    }

    @Test fun benchmark() {
        val out = StringBuilder("JVM ${System.getProperty("java.version")}, ${Runtime.getRuntime().availableProcessors()} CPUs (build container, not a phone)\n")
        val bytes = ModelFiles.textAsset.readBytes()
        val loader = ModelLoader { File(ModelFiles.assets, it).inputStream() }

        val before = usedHeap()
        val model = TextModel.parse(loader.load(BuiltInModels.TEXT_V1))
        val after = usedHeap()
        out.append("text model file: ${bytes.size} bytes; heap after load: ~${(after - before) / 1024} KiB\n")

        val (loadWall, _) = medianMicros(50) { TextModel.parse(loader.load(BuiltInModels.TEXT_V1)) }
        out.append("model load + SHA-256 verify + parse: median %.0f µs\n".format(loadWall))

        val adapter = com.safeguard.app.engine.ai.text.LocalTextClassifierAdapter("t", { model })
        val queries = listOf("online casino bonus", "weather tomorrow in riyadh", "افلام اباحية مجانية", "how to build a bomb at home now please")
        val (textWall, textCpu) = medianMicros(2000) { for (q in queries) adapter.classify(ContentInput.Text(q)) }
        out.append("text inference (normalise + features + 6 sigmoids): median %.1f µs/query (wall), mean CPU %.1f µs/query incl. outliers\n".format(textWall / 4, textCpu / 4))

        val features = TextFeatures.extract("online casino bonus")
        out.append("features per short query: ${features.indices.size}\n")

        val spec = ModelInputSpec(size = 224)
        val img = FakeDecoder.FakeImage(1000, 750, 0xFF808080.toInt()) // a 4000×3000 photo after 4× subsampling
        val tensor = FloatArray(spec.tensorLength)
        val (prepWall, prepCpu) = medianMicros(40) { ImagePreprocessor.toTensor(img, spec, tensor) }
        out.append("image preprocess 1000×750 → 224×224×3: median %.1f ms (wall), mean CPU %.1f ms\n".format(prepWall / 1000, prepCpu / 1000))
        out.append("image buffers: decoded %d KiB (ARGB), tensor %d KiB\n".format(1000 * 750 * 4 / 1024, spec.tensorLength * 4 / 1024))

        File("build").mkdirs()
        File("build/ai-bench.txt").writeText(out.toString())
        assertTrue(out.toString(), textWall / 4 < 20_000) // < 20 ms/query even on a slow CI box
    }
}
