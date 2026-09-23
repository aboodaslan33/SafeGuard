package com.safeguard.app.data

import com.safeguard.app.engine.ai.AiStatistics
import com.safeguard.app.engine.ai.AiStatsStore
import com.safeguard.app.engine.ai.FalsePositiveReport
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category

/**
 * AI counters (in the shared `counters` table) and false-positive reports
 * (`ai_feedback`). Neither holds any content.
 */
class SqliteAiStatsStore(private val db: SafeGuardDatabase) : AiStatsStore {

    override fun record(detected: List<Category>, blocked: Category?) {
        val names = ArrayList<String>()
        if (detected.isNotEmpty()) names += DETECTIONS
        detected.forEach { names += DETECT_PREFIX + it.id }
        if (blocked != null) {
            names += BLOCKS
            names += BLOCK_PREFIX + blocked.id
        }
        increment(names)
    }

    override fun addReport(report: FalsePositiveReport) {
        val w = db.writableDatabase
        w.execSQL(
            "INSERT INTO ai_feedback(ts, source, category, confidence, verdict) VALUES (?, ?, ?, ?, ?)",
            arrayOf<Any>(report.timestamp, report.source.id, report.category.id, report.confidence, report.verdict),
        )
        w.execSQL("DELETE FROM ai_feedback WHERE id NOT IN (SELECT id FROM ai_feedback ORDER BY ts DESC LIMIT ?)", arrayOf<Any>(MAX_REPORTS))
        increment(listOf(REPORTS, REPORT_PREFIX + report.category.id))
    }

    override fun reports(limit: Int): List<FalsePositiveReport> =
        db.readableDatabase.rawQuery(
            "SELECT ts, source, category, confidence, verdict FROM ai_feedback ORDER BY ts DESC LIMIT ?",
            arrayOf(limit.coerceIn(1, MAX_REPORTS).toString()),
        ).use { c ->
            val out = ArrayList<FalsePositiveReport>()
            while (c.moveToNext()) {
                out += FalsePositiveReport(
                    c.getLong(0),
                    EventSource.fromId(c.getString(1)),
                    Category.fromId(c.getString(2)) ?: Category.UNKNOWN,
                    c.getDouble(3),
                    c.getString(4),
                )
            }
            out
        }

    override fun read(): AiStatistics {
        val all = db.readableDatabase.rawQuery("SELECT name, value FROM counters WHERE name LIKE 'ai\\_%' ESCAPE '\\'", emptyArray())
            .use { c ->
                val m = HashMap<String, Long>()
                while (c.moveToNext()) m[c.getString(0)] = c.getLong(1)
                m
            }
        fun byCategory(prefix: String) = Category.filterable
            .mapNotNull { cat -> all[prefix + cat.id]?.let { cat to it } }.toMap()
        return AiStatistics(
            detections = all[DETECTIONS] ?: 0,
            blocks = all[BLOCKS] ?: 0,
            falsePositiveReports = all[REPORTS] ?: 0,
            detectionsByCategory = byCategory(DETECT_PREFIX),
            blocksByCategory = byCategory(BLOCK_PREFIX),
            reportsByCategory = byCategory(REPORT_PREFIX),
        )
    }

    override fun clear() {
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            w.execSQL("DELETE FROM counters WHERE name LIKE 'ai\\_%' ESCAPE '\\'")
            w.execSQL("DELETE FROM ai_feedback")
            w.setTransactionSuccessful()
        } finally {
            w.endTransaction()
        }
    }

    private fun increment(names: List<String>) {
        if (names.isEmpty()) return
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            for (n in names) {
                w.execSQL("INSERT OR IGNORE INTO counters(name, value) VALUES (?, 0)", arrayOf<Any>(n))
                w.execSQL("UPDATE counters SET value = value + 1 WHERE name = ?", arrayOf<Any>(n))
            }
            w.setTransactionSuccessful()
        } finally {
            w.endTransaction()
        }
    }

    private companion object {
        const val DETECTIONS = "ai_detections"
        const val BLOCKS = "ai_blocks"
        const val REPORTS = "ai_fp_reports"
        const val DETECT_PREFIX = "ai_detect:"
        const val BLOCK_PREFIX = "ai_block:"
        const val REPORT_PREFIX = "ai_report:"
        const val MAX_REPORTS = 500
    }
}
