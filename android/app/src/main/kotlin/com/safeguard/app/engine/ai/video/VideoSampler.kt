package com.safeguard.app.engine.ai.video

import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.image.DecodedImage

/**
 * Future video support (not wired to anything in this version).
 *
 * Never analyses every frame: frames are taken at a fixed interval, capped
 * in number, and sampling stops at the first result the caller considers
 * decisive. There is no continuous or background video monitoring.
 */
data class SamplingPlan(
    val intervalMs: Long = 5_000,
    val maxFrames: Int = 12,
    /** Skip intros/black frames. */
    val startOffsetMs: Long = 1_000,
) {
    init {
        require(intervalMs >= 1_000) { "interval must be ≥ 1 s" }
        require(maxFrames in 1..60)
        require(startOffsetMs >= 0)
    }

    /** Timestamps to sample for a video of [durationMs]; always within the video. */
    fun timestamps(durationMs: Long): List<Long> {
        if (durationMs <= 0) return emptyList()
        val first = if (startOffsetMs < durationMs) startOffsetMs else durationMs / 2
        val out = ArrayList<Long>()
        var t = first
        while (t < durationMs && out.size < maxFrames) {
            out += t
            t += intervalMs
        }
        return out
    }
}

/** Supplies one decoded frame (e.g. MediaMetadataRetriever); null if unavailable. */
fun interface VideoFrameSource {
    fun frameAt(timeMs: Long): DecodedImage?
}

class VideoSampler(
    private val plan: SamplingPlan,
    private val classifyFrame: (DecodedImage) -> ClassificationResult,
) {
    /**
     * Classifies sampled frames in order and returns the results so far,
     * stopping early when [isDecisive] returns true. Every frame is closed.
     */
    fun sample(
        durationMs: Long,
        source: VideoFrameSource,
        isDecisive: (ClassificationResult) -> Boolean,
    ): List<ClassificationResult> {
        val results = ArrayList<ClassificationResult>()
        for (t in plan.timestamps(durationMs)) {
            val frame = source.frameAt(t) ?: continue
            val r = frame.use(classifyFrame)
            results += r
            if (isDecisive(r)) break
        }
        return results
    }
}
