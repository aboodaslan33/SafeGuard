package com.safeguard.app.data

import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockEventStore
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.RuleAction

class SqliteBlockEventStore(private val db: SafeGuardDatabase) : BlockEventStore {

    override fun insert(event: BlockEvent) {
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            w.execSQL(
                "INSERT INTO block_events(ts, domain, category, source, action, confidence, rule_type) " +
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                arrayOf<Any>(
                    event.timestamp,
                    event.subject,
                    event.category.id,
                    event.source.id,
                    event.action.name.lowercase(),
                    event.confidence,
                    event.ruleType,
                ),
            )
            if (event.action == RuleAction.BLOCK) {
                // UPSERT syntax needs SQLite 3.24 (Android 11+); minSdk is 24.
                w.execSQL("INSERT OR IGNORE INTO counters(name, value) VALUES (?, 0)", arrayOf<Any>(TOTAL))
                w.execSQL("UPDATE counters SET value = value + 1 WHERE name = ?", arrayOf<Any>(TOTAL))
            }
            w.setTransactionSuccessful()
        } finally {
            w.endTransaction()
        }
    }

    override fun recent(limit: Int): List<BlockEvent> =
        db.readableDatabase.rawQuery(
            "SELECT ts, domain, category, source, action, confidence, rule_type FROM block_events ORDER BY ts DESC LIMIT ?",
            arrayOf(limit.coerceIn(1, 1000).toString()),
        ).use { c ->
            val out = ArrayList<BlockEvent>(c.count)
            while (c.moveToNext()) {
                out += BlockEvent(
                    timestamp = c.getLong(0),
                    subject = c.getString(1),
                    category = Category.fromId(c.getString(2)) ?: Category.UNKNOWN,
                    source = EventSource.fromId(c.getString(3)),
                    action = if (c.getString(4) == "allow") RuleAction.ALLOW else RuleAction.BLOCK,
                    confidence = c.getDouble(5),
                    ruleType = c.getString(6),
                )
            }
            out
        }

    override fun countSince(since: Long): Int =
        db.readableDatabase.rawQuery(
            "SELECT COUNT(*) FROM block_events WHERE ts >= ? AND action = 'block'",
            arrayOf(since.toString()),
        )
            .use { if (it.moveToFirst()) it.getInt(0) else 0 }

    override fun countByCategorySince(since: Long): Map<Category, Int> =
        db.readableDatabase.rawQuery(
            "SELECT category, COUNT(*) FROM block_events WHERE ts >= ? AND action = 'block' GROUP BY category",
            arrayOf(since.toString()),
        ).use { c ->
            val out = HashMap<Category, Int>()
            while (c.moveToNext()) {
                val category = Category.fromId(c.getString(0)) ?: continue
                out[category] = c.getInt(1)
            }
            out
        }

    override fun countBySourceSince(since: Long): Map<EventSource, Int> =
        db.readableDatabase.rawQuery(
            "SELECT source, COUNT(*) FROM block_events WHERE ts >= ? AND action = 'block' GROUP BY source",
            arrayOf(since.toString()),
        ).use { c ->
            val out = HashMap<EventSource, Int>()
            while (c.moveToNext()) {
                val source = EventSource.entries.firstOrNull { it.id == c.getString(0) } ?: continue
                out[source] = c.getInt(1)
            }
            out
        }

    override fun lifetimeTotal(): Long =
        db.readableDatabase.rawQuery("SELECT value FROM counters WHERE name = ?", arrayOf(TOTAL))
            .use { if (it.moveToFirst()) it.getLong(0) else 0L }

    override fun prune(before: Long, maxRows: Int) {
        val w = db.writableDatabase
        w.execSQL("DELETE FROM block_events WHERE ts < ?", arrayOf<Any>(before))
        w.execSQL(
            "DELETE FROM block_events WHERE id NOT IN (SELECT id FROM block_events ORDER BY ts DESC LIMIT ?)",
            arrayOf<Any>(maxRows),
        )
    }

    override fun clear() {
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            w.execSQL("DELETE FROM block_events")
            w.execSQL("DELETE FROM counters WHERE name = ?", arrayOf<Any>(TOTAL))
            w.setTransactionSuccessful()
        } finally {
            w.endTransaction()
        }
    }

    private companion object {
        const val TOTAL = "blocked_total"
    }
}
