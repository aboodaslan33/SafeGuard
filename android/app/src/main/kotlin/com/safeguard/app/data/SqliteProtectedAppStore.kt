package com.safeguard.app.data

import com.safeguard.app.engine.apps.ProtectedApp
import com.safeguard.app.engine.apps.ProtectedAppStore

/**
 * Protected apps in SQLite, with an in-memory copy: [contains] runs on the
 * accessibility service's main thread for every foreground-app change, so
 * it must not touch the disk.
 */
class SqliteProtectedAppStore(private val db: SafeGuardDatabase) : ProtectedAppStore {

    @Volatile private var cache: Map<String, ProtectedApp>? = null

    private fun snapshot(): Map<String, ProtectedApp> = cache ?: synchronized(this) {
        cache ?: load().also { cache = it }
    }

    private fun load(): Map<String, ProtectedApp> =
        db.readableDatabase.rawQuery("SELECT package, added_at FROM protected_apps ORDER BY package", emptyArray())
            .use { c ->
                val out = LinkedHashMap<String, ProtectedApp>()
                while (c.moveToNext()) out[c.getString(0)] = ProtectedApp(c.getString(0), c.getLong(1))
                out
            }

    override fun list(): List<ProtectedApp> = snapshot().values.toList()

    override fun contains(packageName: String): Boolean = packageName in snapshot()

    @Synchronized
    override fun add(app: ProtectedApp): Boolean {
        db.writableDatabase.execSQL(
            "INSERT OR IGNORE INTO protected_apps(package, added_at) VALUES (?, ?)",
            arrayOf<Any>(app.packageName, app.addedAt),
        )
        cache = null
        return true
    }

    @Synchronized
    override fun remove(packageName: String): Boolean {
        val removed = db.writableDatabase.delete("protected_apps", "package = ?", arrayOf(packageName)) > 0
        cache = null
        return removed
    }

    override fun count(): Int = snapshot().size

    @Synchronized
    override fun clear() {
        db.writableDatabase.delete("protected_apps", null, null)
        cache = null
    }
}
