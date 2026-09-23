package com.safeguard.app.data

import android.content.ContentValues
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.search.CustomKeyword
import com.safeguard.app.engine.search.CustomKeywordStore

/**
 * User keywords in SQLite with an in-memory copy (read on every submitted
 * search). Phrases arrive already validated and normalised.
 */
class SqliteCustomKeywordStore(private val db: SafeGuardDatabase) : CustomKeywordStore {
    @Volatile private var cache: List<CustomKeyword>? = null

    override fun list(): List<CustomKeyword> = cache ?: synchronized(this) {
        cache ?: load().also { cache = it }
    }

    private fun load(): List<CustomKeyword> =
        db.readableDatabase.rawQuery("SELECT id, phrase, category, added_at FROM custom_keywords ORDER BY id", emptyArray())
            .use { c ->
                val out = ArrayList<CustomKeyword>()
                while (c.moveToNext()) {
                    val category = Category.fromId(c.getString(2)) ?: continue
                    out += CustomKeyword(c.getLong(0), c.getString(1), category, c.getLong(3))
                }
                out
            }

    @Synchronized
    override fun add(phrase: String, category: Category, addedAt: Long): CustomKeyword {
        // insertOrThrow returns the row id on the same connection (a separate
        // "SELECT last_insert_rowid()" may run on another pooled connection).
        val id = db.writableDatabase.insertOrThrow(
            "custom_keywords",
            null,
            ContentValues().apply {
                put("phrase", phrase)
                put("category", category.id)
                put("added_at", addedAt)
            },
        )
        cache = null
        return CustomKeyword(id, phrase, category, addedAt)
    }

    @Synchronized
    override fun remove(id: Long): Boolean {
        val n = db.writableDatabase.delete("custom_keywords", "id = ?", arrayOf(id.toString()))
        cache = null
        return n > 0
    }

    override fun count(): Int = list().size

    @Synchronized
    override fun clear() {
        db.writableDatabase.execSQL("DELETE FROM custom_keywords")
        cache = null
    }
}
