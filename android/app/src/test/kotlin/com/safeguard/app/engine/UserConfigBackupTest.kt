package com.safeguard.app.engine

import com.safeguard.app.engine.backup.KeywordEntry
import com.safeguard.app.engine.backup.UserConfig
import com.safeguard.app.engine.backup.UserConfigBackup
import com.safeguard.app.engine.backup.UserRuleEntry
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.RuleAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UserConfigBackupTest {
    private val config = UserConfig(
        rules = listOf(
            UserRuleEntry("mine.test", RuleAction.BLOCK, Category.CUSTOM, true),
            UserRuleEntry("school.test", RuleAction.ALLOW, Category.CUSTOM, false),
        ),
        keywords = listOf(KeywordEntry("online casino", Category.GAMBLING), KeywordEntry("قمار اونلاين", Category.GAMBLING)),
        protectedApps = listOf("com.example.game"),
    )

    @Test fun roundTrips() {
        assertEquals(config, UserConfigBackup.decode(UserConfigBackup.encode(config)))
    }

    @Test fun rejectsNonBackupsAndSkipsBadLines() {
        assertNull(UserConfigBackup.decode("hello"))
        val text = UserConfigBackup.encode(config) + listOf(
            "r\tB\tnot a domain\tcustom\t1",
            "r\tX\tok.test\tcustom\t1",
            "r\tB\tok.test\tnot_a_category\t1",
            "k\tgambling\tab",
            "a\t../../etc/passwd",
            "z\twhatever",
        ).joinToString("\n")
        val decoded = UserConfigBackup.decode(text)!!
        assertEquals(config, decoded)
    }

    @Test fun emptyConfig() {
        assertTrue(UserConfigBackup.decode(UserConfigBackup.encode(UserConfig(emptyList(), emptyList(), emptyList())))!!.isEmpty)
    }
}
