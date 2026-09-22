package com.safeguard.app.data

import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockEventStore
import com.safeguard.app.engine.rules.Category

class SqliteBlockEventStore(private val db: SafeGuardDatabase) : BlockEventStore {

    override fun insert(event: BlockEvent) {
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            w.execSQL(
                "INSERT INTO block_events(ts, domain, category) VALUES (?, ?, ?)",
                arrayOf<Any>(event.timestamp, event.domain, event.category.id),
            )
            // UPSERT syntax needs SQLite 3.24 (Android 11+); minSdk is 24.
            w.execSQL("INSERT OR IGNORE INTO counters(name, value) VALUES (?, 0)", arrayOf<Any>(TOTAL))
            w.execSQL("UPDATE counters SET value = value + 1 WHERE name = ?", arrayOf<Any>(TOTAL))
            w.setTransactionSuccessful()
        } finally {
            w.endTransaction()
        }
    }

    override fun recent(limit: Int): List<BlockEvent> =
        db.readableDatabase.rawQuery(
            "SELECT ts, domain, category FROM block_events ORDER BY ts DESC LIMIT ?",
            arrayOf(limit.coerceIn(1, 1000).toString()),
        ).use { c ->
            val out = ArrayList<BlockEvent>(c.count)
            while (c.moveToNext()) {
                out += BlockEvent(c.getLong(0), c.getString(1), Category.fromId(c.getString(2)) ?: Category.UNKNOWN)
            }
            out
        }

    override fun countSince(since: Long): Int =
        db.readableDatabase.rawQuery("SELECT COUNT(*) FROM block_events WHERE ts >= ?", arrayOf(since.toString()))
            .use { if (it.moveToFirst()) it.getInt(0) else 0 }

    override fun countByCategorySince(since: Long): Map<Category, Int> =
        db.readableDatabase.rawQuery(
            "SELECT category, COUNT(*) FROM block_events WHERE ts >= ? GROUP BY category",
            arrayOf(since.toString()),
        ).use { c ->
            val out = HashMap<Category, Int>()
            while (c.moveToNext()) {
                val category = Category.fromId(c.getString(0)) ?: continue
                out[category] = c.getInt(1)
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
