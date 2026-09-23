package com.safeguard.app.engine.logging

import com.safeguard.app.engine.dns.BlockListener
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.LruCache
import com.safeguard.app.engine.rules.RuleAction
import java.util.concurrent.Executor

/** Where a protection event originated. [id] is stored; never rename. */
enum class EventSource(val id: String) {
    DNS("dns"),
    SEARCH("search"),
    APP("app"),

    /** Reserved for Phase 4 on-device classification. */
    AI("ai"),

    /** User-initiated (e.g. manual block test). */
    MANUAL("manual");

    companion object {
        fun fromId(id: String?) = entries.firstOrNull { it.id == id } ?: DNS
    }
}

/**
 * One protection event. This is the *entire* record:
 *
 * - [subject]: for DNS the blocked domain; for SEARCH a rule id plus a keyed
 *   short hash (never the query); for APP the protected package name.
 * - no IP addresses, URLs, page content, messages, passwords or tokens.
 */
data class BlockEvent(
    val timestamp: Long,
    val subject: String,
    val category: Category,
    val source: EventSource = EventSource.DNS,
    val action: RuleAction = RuleAction.BLOCK,
    /** 0..1; 1.0 for exact rules (domains, protected apps). */
    val confidence: Double = 1.0,
    /** "domain", "keyword", "protected_app", later "ai". */
    val ruleType: String = RULE_TYPE_DOMAIN,
) {
    /** Phase 2 name of [subject]. */
    val domain: String get() = subject

    companion object {
        const val RULE_TYPE_DOMAIN = "domain"
        const val RULE_TYPE_KEYWORD = "keyword"
        const val RULE_TYPE_PROTECTED_APP = "protected_app"
        const val RULE_TYPE_TEMPORARY_UNLOCK = "temporary_unlock"
    }
}

typealias ProtectionEvent = BlockEvent

/**
 * Event storage. Counting methods count **blocks only** (action BLOCK);
 * other events (e.g. a MANUAL temporary unlock) are listed but not counted.
 */
interface BlockEventStore {
    fun insert(event: BlockEvent)
    fun recent(limit: Int): List<BlockEvent>
    fun countSince(since: Long): Int
    fun countByCategorySince(since: Long): Map<Category, Int>
    fun countBySourceSince(since: Long): Map<EventSource, Int>

    /** Lifetime block count; survives log pruning and is reset only by [clear]. */
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
        if (event.action == RuleAction.BLOCK) total++
    }

    @Synchronized override fun recent(limit: Int) =
        events.sortedByDescending { it.timestamp }.take(limit)

    private fun blocksSince(since: Long) = events.filter { it.timestamp >= since && it.action == RuleAction.BLOCK }

    @Synchronized override fun countSince(since: Long) = blocksSince(since).size

    @Synchronized override fun countByCategorySince(since: Long) =
        blocksSince(since).groupingBy { it.category }.eachCount()

    @Synchronized override fun countBySourceSince(since: Long) =
        blocksSince(since).groupingBy { it.source }.eachCount()

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
    private val maxRows: Int = 10_000,
    /** User setting; read on every event so changes apply immediately. */
    private val retention: () -> LogRetention = { LogRetention.DEFAULT },
) : BlockListener {
    private val lastLogged = LruCache<String, Long>(512)
    private var insertsSincePrune = 0
    private val writeFailures = java.util.concurrent.atomic.AtomicLong()

    /** Log writes that failed (e.g. storage full); shown in diagnostics. */
    val failedWrites: Long get() = writeFailures.get()

    /** Current time on the logger's clock (for non-DNS event sources). */
    fun now(): Long = clock()

    override fun onBlocked(decision: Decision) {
        val domain = decision.domain ?: return
        record(BlockEvent(clock(), domain, decision.category))
    }

    /**
     * Records any event (DNS, SEARCH, APP…). Callers are responsible for
     * [BlockEvent.subject] being non-sensitive; see `SearchEventRecorder`.
     */
    fun record(event: BlockEvent) {
        val policy = retention()
        if (!policy.keepsLog) return
        val now = event.timestamp
        val key = event.source.id + ":" + event.subject
        synchronized(this) {
            val previous = lastLogged.get(key)
            if (previous != null && now - previous < dedupeWindowMs) return
            lastLogged.put(key, now)
        }
        executor.execute {
            // Disk full / I/O errors must never crash the process (and with
            // it the VPN): losing one log row is the safe failure.
            try {
                store.insert(event)
                if (++insertsSincePrune >= 200) {
                    insertsSincePrune = 0
                    store.prune(now - policy.retentionMs, maxRows)
                }
            } catch (e: RuntimeException) {
                writeFailures.incrementAndGet()
            }
        }
    }

    /**
     * Deletes what the current [retention] no longer allows (at start-up and
     * after the setting changes). [LogRetention.NEVER] removes every event
     * row but keeps the lifetime counter.
     */
    fun applyRetention() {
        val policy = retention()
        val now = clock()
        executor.execute {
            try {
                if (policy.keepsLog) store.prune(now - policy.retentionMs, maxRows) else store.prune(Long.MAX_VALUE, 0)
            } catch (e: RuntimeException) {
                writeFailures.incrementAndGet()
            }
        }
    }

    /** Forget dedupe state (after the user clears the log). */
    fun reset() = lastLogged.clear()
}
