package com.safeguard.app.ai

import com.safeguard.app.engine.shield.ImageInferenceRuntime
import com.safeguard.app.engine.shield.ImageModelPack
import com.safeguard.app.engine.shield.ImageRuntimeFactory
import com.safeguard.app.engine.shield.TensorLayout
import org.tensorflow.lite.InterpreterApi
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * On-device image inference with LiteRT (TensorFlow Lite). Runs a pinned,
 * SHA-256-verified `.tflite` file — a data file interpreted by the bundled
 * runtime, never downloaded code. The interpreter and its buffers live
 * until [close] (called when the shield or protection stops).
 */
class LiteRtImageRuntime private constructor(
    private val interpreter: InterpreterApi,
    tensorLength: Int,
    labels: Int,
) : ImageInferenceRuntime {

    private val input: ByteBuffer = ByteBuffer.allocateDirect(tensorLength * 4).order(ByteOrder.nativeOrder())
    private val output = Array(1) { FloatArray(labels) }

    override fun run(input: FloatArray): FloatArray {
        val buf = this.input
        buf.clear()
        buf.asFloatBuffer().put(input)
        try {
            interpreter.run(buf, output)
        } finally {
            // Don't keep the (downscaled) screen tensor around between frames.
            buf.clear()
            while (buf.remaining() >= 8) buf.putLong(0L)
            buf.clear()
        }
        return output[0].copyOf()
    }

    override fun close() = interpreter.close()

    companion object {
        /** Opens a model; checks that its tensors match the pack before any frame is run. */
        val factory = ImageRuntimeFactory { pack, model -> open(pack, model) }

        private fun open(pack: ImageModelPack, model: ByteBuffer): LiteRtImageRuntime {
            require(pack.layout == TensorLayout.NHWC) { "LiteRT pack must be NHWC" }
            val direct = if (model.isDirect) model else ByteBuffer.allocateDirect(model.capacity()).put(model.duplicate()).also { it.rewind() }
            val options = InterpreterApi.Options()
                .setNumThreads(2)
                .setRuntime(InterpreterApi.Options.TfLiteRuntime.FROM_APPLICATION_ONLY)
            val interpreter = InterpreterApi.create(direct, options)
            try {
                val inShape = interpreter.getInputTensor(0).shape()
                val outShape = interpreter.getOutputTensor(0).shape()
                val n = pack.input.size
                require(inShape.contentEquals(intArrayOf(1, n, n, 3))) { "input shape" }
                require(outShape.contentEquals(intArrayOf(1, pack.labels.size))) { "output shape" }
            } catch (e: RuntimeException) {
                interpreter.close()
                throw e
            }
            return LiteRtImageRuntime(interpreter, pack.input.tensorLength, pack.labels.size)
        }
    }
}
