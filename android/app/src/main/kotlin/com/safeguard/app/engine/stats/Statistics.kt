package com.safeguard.app.engine.stats

import com.safeguard.app.engine.logging.BlockEventStore
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

class StatisticsService(
    private val store: BlockEventStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: () -> ZoneId = ZoneId::systemDefault,
) {
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
