package com.safeguard.app.engine.logging

import com.safeguard.app.engine.dns.BlockListener
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.LruCache
import java.util.concurrent.Executor

/**
 * One blocked lookup. This is the *entire* record: time, domain, category.
 * No app identity, no IP addresses, no URLs, no content.
 */
data class BlockEvent(
    val timestamp: Long,
    val domain: String,
    val category: Category,
)

interface BlockEventStore {
    fun insert(event: BlockEvent)
    fun recent(limit: Int): List<BlockEvent>
    fun countSince(since: Long): Int
    fun countByCategorySince(since: Long): Map<Category, Int>

    /** Lifetime count; survives log pruning and is reset only by [clear]. */
    fun lifetimeTotal(): Long

    /** Deletes events older than [before] and keeps at most [maxRows]. */
    fun prune(before: Long, maxRows: Int)
    fun clear()
}

class InMemoryBlockEventStore : BlockEventStore {
    private val events = ArrayList<BlockEvent>()
    private var total = 0L

    @Synchronized override fun insert(event: BlockEvent) {
        events.add(event)
        total++
    }

    @Synchronized override fun recent(limit: Int) =
        events.sortedByDescending { it.timestamp }.take(limit)

    @Synchronized override fun countSince(since: Long) = events.count { it.timestamp >= since }

    @Synchronized override fun countByCategorySince(since: Long) =
        events.filter { it.timestamp >= since }.groupingBy { it.category }.eachCount()

    @Synchronized override fun lifetimeTotal() = total

    @Synchronized override fun prune(before: Long, maxRows: Int) {
        events.removeAll { it.timestamp < before }
        if (events.size > maxRows) {
            events.sortBy { it.timestamp }
            repeat(events.size - maxRows) { events.removeAt(0) }
        }
    }

    @Synchronized override fun clear() {
        events.clear()
        total = 0
    }
}

/**
 * Records BLOCK decisions off the DNS thread.
 *
 * A single page load triggers several lookups for the same name (A, AAAA,
 * HTTPS records, retries), so repeats of one domain within
 * [dedupeWindowMs] count as one event. Old events are pruned periodically.
 */
class BlockLogger(
    private val store: BlockEventStore,
    private val executor: Executor,
    private val clock: () -> Long = System::currentTimeMillis,
    private val dedupeWindowMs: Long = 30_000,
    private val retentionMs: Long = 30L * 24 * 60 * 60 * 1000,
    private val maxRows: Int = 10_000,
) : BlockListener {
    private val lastLogged = LruCache<String, Long>(512)
    private var insertsSincePrune = 0

    override fun onBlocked(decision: Decision) {
        val domain = decision.domain ?: return
        val now = clock()
        synchronized(this) {
            val previous = lastLogged.get(domain)
            if (previous != null && now - previous < dedupeWindowMs) return
            lastLogged.put(domain, now)
        }
        val event = BlockEvent(now, domain, decision.category)
        executor.execute {
            store.insert(event)
            if (++insertsSincePrune >= 200) {
                insertsSincePrune = 0
                store.prune(now - retentionMs, maxRows)
            }
        }
    }

    /** Forget dedupe state (after the user clears the log). */
    fun reset() = lastLogged.clear()
}
