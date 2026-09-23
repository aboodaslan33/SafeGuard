package com.safeguard.app.engine.stats

import com.safeguard.app.engine.logging.BlockEventStore
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category
import java.time.Instant
import java.time.ZoneId

data class BlockStatistics(
    /** Since local midnight. */
    val today: Int,
    /** Rolling last 7 days. */
    val last7Days: Int,
    /** Lifetime (not limited by log retention). */
    val total: Long,
    /** Rolling last 30 days (log retention window), per category. */
    val byCategory: Map<Category, Int>,
)

/** Blocks in one period. Counts only; no subjects. */
data class WindowStatistics(
    val total: Int,
    /** DNS = domains, SEARCH = search rules/keywords, AI = model decisions, APP = protected apps. */
    val bySource: Map<EventSource, Int>,
    val byCategory: Map<Category, Int>,
    val falsePositiveReports: Int,
)

data class DetailedStatistics(
    val today: WindowStatistics,
    val last7Days: WindowStatistics,
    val last30Days: WindowStatistics,
)

class StatisticsService(
    private val store: BlockEventStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: () -> ZoneId = ZoneId::systemDefault,
    /** False-positive reports since a time (AI feedback store). */
    private val reportsSince: (Long) -> Int = { 0 },
) {
    /** Today (since local midnight), rolling 7 and 30 days (log retention). */
    fun detailed(): DetailedStatistics {
        val now = clock()
        fun window(since: Long) = WindowStatistics(
            total = store.countSince(since),
            bySource = store.countBySourceSince(since),
            byCategory = store.countByCategorySince(since),
            falsePositiveReports = reportsSince(since),
        )
        return DetailedStatistics(window(startOfDay(now)), window(now - 7 * DAY), window(now - 30 * DAY))
    }

    private fun startOfDay(now: Long) = Instant.ofEpochMilli(now).atZone(zone()).toLocalDate()
        .atStartOfDay(zone()).toInstant().toEpochMilli()

    fun compute(): BlockStatistics {
        val now = clock()
        val startOfDay = Instant.ofEpochMilli(now).atZone(zone()).toLocalDate()
            .atStartOfDay(zone()).toInstant().toEpochMilli()
        return BlockStatistics(
            today = store.countSince(startOfDay),
            last7Days = store.countSince(now - 7 * DAY),
            total = store.lifetimeTotal(),
            byCategory = store.countByCategorySince(now - 30 * DAY),
        )
    }

    private companion object {
        const val DAY = 24L * 60 * 60 * 1000
    }
}
