package com.safeguard.app.data

import android.database.sqlite.SQLiteDatabase
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * Upgrading from the first shipped schema (v1, Phase 2) to the current one
 * keeps the user's rules and log. Not executable in the development
 * container (no Android SDK); runs in CI (`testProdDebugUnitTest`).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 34], manifest = Config.NONE)
class MigrationTest {
    private val context = RuntimeEnvironment.getApplication()

    private fun createV1() {
        val file = context.getDatabasePath(SafeGuardDatabase.NAME)
        file.parentFile?.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(file, null).use { db ->
            // Verbatim v1 schema (commit 42c3990).
            db.execSQL(
                """
                CREATE TABLE rules (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, domain TEXT NOT NULL, category TEXT NOT NULL,
                    action TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, source TEXT NOT NULL,
                    version INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL, UNIQUE(domain, source)
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE INDEX idx_rules_domain ON rules(domain)")
            db.execSQL("CREATE INDEX idx_rules_source_action ON rules(source, action)")
            db.execSQL("CREATE TABLE block_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, domain TEXT NOT NULL, category TEXT NOT NULL)")
            db.execSQL("CREATE INDEX idx_events_ts ON block_events(ts)")
            db.execSQL("CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            db.execSQL("INSERT INTO rules(domain, category, action, source, updated_at) VALUES ('mine.test', 'custom', 'BLOCK', 'user', 1)")
            db.execSQL("INSERT INTO rules(domain, category, action, source, updated_at) VALUES ('school.test', 'unknown', 'ALLOW', 'user', 1)")
            db.execSQL("INSERT INTO block_events(ts, domain, category) VALUES (5, 'mine.test', 'custom')")
            db.version = 1
        }
    }

    @Test
    fun v1ToCurrentKeepsUserRulesAndLog() {
        createV1()
        val db = SafeGuardDatabase(context)
        assertEquals(SafeGuardDatabase.VERSION, db.readableDatabase.version)
        val rules = SqliteRuleStore(db)
        val user = rules.list(RuleSource.USER, null, 100, 0)
        assertEquals(setOf("mine.test", "school.test"), user.map { it.domain }.toSet())
        // v4 default: pre-existing rules keep covering subdomains.
        assertTrue(user.all { it.includeSubdomains })
        assertEquals(RuleAction.ALLOW, user.first { it.domain == "school.test" }.action)
        val events = SqliteBlockEventStore(db).recent(10)
        assertEquals(1, events.size)
        assertEquals("dns", events.single().source.id)
        assertTrue(!db.createdFresh)
        db.close()
    }
}
