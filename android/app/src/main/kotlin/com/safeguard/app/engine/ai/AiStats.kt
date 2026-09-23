package com.safeguard.app.engine.ai

import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category

/** Aggregate AI counters. Counts only — no content, no per-item identifiers. */
data class AiStatistics(
    /** Classifications where some category reached its threshold (enabled or not). */
    val detections: Long = 0,
    /** Content blocked because of an AI result. */
    val blocks: Long = 0,
    val falsePositiveReports: Long = 0,
    val detectionsByCategory: Map<Category, Long> = emptyMap(),
    val blocksByCategory: Map<Category, Long> = emptyMap(),
    val reportsByCategory: Map<Category, Long> = emptyMap(),
)

/**
 * "Report incorrect block". This is the entire record: the blocked content
 * is never attached, and confidence is rounded to two decimals.
 */
data class FalsePositiveReport(
    val timestamp: Long,
    val source: EventSource,
    val category: Category,
    val confidence: Double,
    val verdict: String = VERDICT_INCORRECT_BLOCK,
) {
    companion object {
        const val VERDICT_INCORRECT_BLOCK = "incorrect_block"

        fun of(timestamp: Long, source: EventSource, category: Category, confidence: Double) = FalsePositiveReport(
            timestamp,
            source,
            category,
            Math.round(confidence.coerceIn(0.0, 1.0) * 100) / 100.0,
        )
    }
}

interface AiStatsStore {
    /** Adds one detection per category in [detected] and, if [blocked], one block. */
    fun record(detected: List<Category>, blocked: Category?)
    fun addReport(report: FalsePositiveReport)
    fun reports(limit: Int): List<FalsePositiveReport>
    fun reportsSince(since: Long): Int
    fun read(): AiStatistics
    fun clear()
}

class InMemoryAiStatsStore : AiStatsStore {
    private var s = AiStatistics()
    private val reports = ArrayList<FalsePositiveReport>()

    @Synchronized override fun record(detected: List<Category>, blocked: Category?) {
        s = s.copy(
            detections = s.detections + if (detected.isEmpty()) 0 else 1,
            detectionsByCategory = detected.fold(s.detectionsByCategory) { m, c -> m + (c to (m[c] ?: 0) + 1) },
            blocks = s.blocks + if (blocked != null) 1 else 0,
            blocksByCategory = blocked?.let { s.blocksByCategory + (it to (s.blocksByCategory[it] ?: 0) + 1) } ?: s.blocksByCategory,
        )
    }

    @Synchronized override fun addReport(report: FalsePositiveReport) {
        reports += report
        s = s.copy(
            falsePositiveReports = s.falsePositiveReports + 1,
            reportsByCategory = s.reportsByCategory + (report.category to (s.reportsByCategory[report.category] ?: 0) + 1),
        )
    }

    @Synchronized override fun reports(limit: Int) = reports.sortedByDescending { it.timestamp }.take(limit)

    @Synchronized override fun reportsSince(since: Long) = reports.count { it.timestamp >= since }

    @Synchronized override fun read() = s

    @Synchronized override fun clear() {
        s = AiStatistics()
        reports.clear()
    }
}
