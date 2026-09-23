package com.safeguard.app.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Local SQLite database: rules, block events, counters, protected apps
 * and AI feedback.
 *
 * Stored in the app's private data directory; excluded from backup via
 * data_extraction_rules.xml. All queries use bound arguments.
 */
class SafeGuardDatabase(context: Context) :
    SQLiteOpenHelper(context.applicationContext, NAME, null, VERSION) {

    override fun onConfigure(db: SQLiteDatabase) {
        db.enableWriteAheadLogging() // concurrent reads from the DNS thread
    }

    /**
     * True when the schema was created in this process — a first install,
     * or a rebuild after corruption / downgrade. The manager then restores
     * the user's own configuration from its private backup.
     */
    @Volatile var createdFresh = false
        private set

    override fun onCreate(db: SQLiteDatabase) {
        createdFresh = true
        db.execSQL(
            """
            CREATE TABLE rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                domain TEXT NOT NULL,
                category TEXT NOT NULL,
                action TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                source TEXT NOT NULL,
                version INTEGER NOT NULL DEFAULT 1,
                updated_at INTEGER NOT NULL,
                UNIQUE(domain, source)
            )
            """.trimIndent(),
        )
        // Lookups are "domain IN (suffix candidates)", served by this index.
        db.execSQL("CREATE INDEX idx_rules_domain ON rules(domain)")
        db.execSQL("CREATE INDEX idx_rules_source_action ON rules(source, action)")

        db.execSQL(
            """
            CREATE TABLE block_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                domain TEXT NOT NULL,
                category TEXT NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX idx_events_ts ON block_events(ts)")

        db.execSQL("CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        migrateToV2(db)
        migrateToV3(db)
        migrateToV4(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // One step per version; never drop user rules or logs.
        if (oldVersion < 2) migrateToV2(db)
        if (oldVersion < 3) migrateToV3(db)
        if (oldVersion < 4) migrateToV4(db)
    }

    /**
     * An older app version installed over a newer one can't read the newer
     * schema. Rather than failing to open (which would stop the VPN from
     * filtering), start from an empty schema: built-in rules and bundled
     * lists are re-seeded; user lists, keywords and logs are lost.
     * Corruption is handled by SQLite's default error handler, which
     * deletes the damaged file and lets the same re-seeding happen.
     */
    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        val tables = db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name != 'android_metadata'",
            emptyArray(),
        ).use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }
        // Table names come from sqlite_master, not from input; quoted anyway.
        tables.forEach { db.execSQL("DROP TABLE IF EXISTS \"${it.replace("\"", "\"\"")}\"") }
        onCreate(db)
    }

    /**
     * v2 (Phase 3): events carry source/action/confidence/rule type
     * (`domain` now holds the event subject), and protected apps.
     * Existing v1 rows are DNS blocks with confidence 1.
     */
    private fun migrateToV2(db: SQLiteDatabase) {
        db.execSQL("ALTER TABLE block_events ADD COLUMN source TEXT NOT NULL DEFAULT 'dns'")
        db.execSQL("ALTER TABLE block_events ADD COLUMN action TEXT NOT NULL DEFAULT 'block'")
        db.execSQL("ALTER TABLE block_events ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0")
        db.execSQL("ALTER TABLE block_events ADD COLUMN rule_type TEXT NOT NULL DEFAULT 'domain'")
        db.execSQL("CREATE TABLE protected_apps (package TEXT PRIMARY KEY, added_at INTEGER NOT NULL)")
    }

    /**
     * v3 (Phase 4): "report incorrect block" feedback. Only timestamp,
     * source, category, rounded confidence and verdict — never content.
     * AI counters live in `counters` (names prefixed `ai_`).
     */
    private fun migrateToV3(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE ai_feedback (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                source TEXT NOT NULL,
                category TEXT NOT NULL,
                confidence REAL NOT NULL,
                verdict TEXT NOT NULL
            )
            """.trimIndent(),
        )
    }

    /**
     * v4 (Phase 5): allowlist scope (existing rows keep covering subdomains,
     * as before) and user keywords (stored normalised).
     */
    private fun migrateToV4(db: SQLiteDatabase) {
        db.execSQL("ALTER TABLE rules ADD COLUMN include_subdomains INTEGER NOT NULL DEFAULT 1")
        db.execSQL(
            """
            CREATE TABLE custom_keywords (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                phrase TEXT NOT NULL UNIQUE,
                category TEXT NOT NULL,
                added_at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        // Statistics use the existing ts index (checked with EXPLAIN QUERY PLAN).
    }

    /** Cheap liveness check for the health report: opens and reads. */
    fun isHealthy(): Boolean = try {
        readableDatabase.rawQuery("SELECT COUNT(*) FROM meta", emptyArray()).use { it.moveToFirst() }
    } catch (e: Exception) {
        false
    }

    fun getMeta(key: String): String? =
        readableDatabase.rawQuery("SELECT value FROM meta WHERE key = ?", arrayOf(key)).use {
            if (it.moveToFirst()) it.getString(0) else null
        }

    fun setMeta(key: String, value: String) {
        writableDatabase.execSQL("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", arrayOf(key, value))
    }

    companion object {
        const val NAME = "safeguard.db"
        const val VERSION = 4
    }
}
