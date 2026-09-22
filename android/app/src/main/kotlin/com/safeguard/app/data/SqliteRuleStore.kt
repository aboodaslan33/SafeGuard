package com.safeguard.app.data

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.rules.RuleStore

class SqliteRuleStore(private val db: SafeGuardDatabase) : RuleStore {

    override fun findEnabled(domains: Collection<String>): List<Rule> {
        if (domains.isEmpty()) return emptyList()
        // At most ~127 candidates (253-char name), well under SQLite's limit.
        val placeholders = domains.joinToString(",") { "?" }
        return query(
            "SELECT $COLUMNS FROM rules WHERE enabled = 1 AND domain IN ($placeholders)",
            domains.toTypedArray(),
        )
    }

    override fun upsert(rule: Rule) {
        db.writableDatabase.insertWithOnConflict("rules", null, values(rule), SQLiteDatabase.CONFLICT_REPLACE)
    }

    override fun upsertAll(rules: Collection<Rule>) {
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            rules.forEach { w.insertWithOnConflict("rules", null, values(it), SQLiteDatabase.CONFLICT_REPLACE) }
            w.setTransactionSuccessful()
        } finally {
            w.endTransaction()
        }
    }

    override fun delete(domain: String, source: RuleSource): Boolean =
        db.writableDatabase.delete("rules", "domain = ? AND source = ?", arrayOf(domain, source.id)) > 0

    override fun setEnabled(domain: String, source: RuleSource, enabled: Boolean): Boolean {
        val v = ContentValues().apply {
            put("enabled", if (enabled) 1 else 0)
            put("updated_at", System.currentTimeMillis())
        }
        return db.writableDatabase.update("rules", v, "domain = ? AND source = ?", arrayOf(domain, source.id)) > 0
    }

    override fun get(domain: String, source: RuleSource): Rule? =
        query("SELECT $COLUMNS FROM rules WHERE domain = ? AND source = ?", arrayOf(domain, source.id)).firstOrNull()

    override fun list(source: RuleSource?, action: RuleAction?, limit: Int, offset: Int): List<Rule> {
        val where = mutableListOf<String>()
        val args = mutableListOf<String>()
        source?.let { where += "source = ?"; args += it.id }
        action?.let { where += "action = ?"; args += it.name }
        val clause = if (where.isEmpty()) "" else "WHERE " + where.joinToString(" AND ")
        args += limit.coerceIn(1, 5000).toString()
        args += offset.coerceAtLeast(0).toString()
        return query("SELECT $COLUMNS FROM rules $clause ORDER BY domain LIMIT ? OFFSET ?", args.toTypedArray())
    }

    override fun search(query: String, limit: Int): List<Rule> {
        // LIKE wildcards in user input are escaped: the search is literal.
        val escaped = query.lowercase().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        return query(
            "SELECT $COLUMNS FROM rules WHERE domain LIKE ? ESCAPE '\\' ORDER BY domain LIMIT ?",
            arrayOf("%$escaped%", limit.coerceIn(1, 500).toString()),
        )
    }

    override fun count(source: RuleSource?): Int {
        val (sql, args) = if (source == null) {
            "SELECT COUNT(*) FROM rules" to emptyArray()
        } else {
            "SELECT COUNT(*) FROM rules WHERE source = ?" to arrayOf(source.id)
        }
        return db.readableDatabase.rawQuery(sql, args).use { if (it.moveToFirst()) it.getInt(0) else 0 }
    }

    /** Rules that can block something right now (enabled BLOCK rules). */
    fun countBlocking(): Int =
        db.readableDatabase.rawQuery("SELECT COUNT(*) FROM rules WHERE enabled = 1 AND action = ?", arrayOf(RuleAction.BLOCK.name))
            .use { if (it.moveToFirst()) it.getInt(0) else 0 }

    override fun deleteSource(source: RuleSource) {
        db.writableDatabase.delete("rules", "source = ?", arrayOf(source.id))
    }

    private fun query(sql: String, args: Array<String>): List<Rule> =
        db.readableDatabase.rawQuery(sql, args).use { c ->
            val out = ArrayList<Rule>(c.count)
            while (c.moveToNext()) read(c)?.let(out::add)
            out
        }

    /** Rows with unknown enum values (e.g. from a newer version) are skipped. */
    private fun read(c: Cursor): Rule? {
        val category = Category.fromId(c.getString(1)) ?: return null
        val action = RuleAction.entries.firstOrNull { it.name == c.getString(2) } ?: return null
        val source = RuleSource.fromId(c.getString(4)) ?: return null
        return Rule(
            domain = c.getString(0),
            category = category,
            action = action,
            enabled = c.getInt(3) == 1,
            source = source,
            version = c.getInt(5),
            updatedAt = c.getLong(6),
        )
    }

    private fun values(rule: Rule) = ContentValues().apply {
        put("domain", rule.domain)
        put("category", rule.category.id)
        put("action", rule.action.name)
        put("enabled", if (rule.enabled) 1 else 0)
        put("source", rule.source.id)
        put("version", rule.version)
        put("updated_at", rule.updatedAt)
    }

    private companion object {
        const val COLUMNS = "domain, category, action, enabled, source, version, updated_at"
    }
}
