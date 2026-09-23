package com.safeguard.app.engine.backup

import com.safeguard.app.engine.domain.DomainName
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.RuleAction

/**
 * The user's own protection configuration that lives in SQLite: block /
 * allow rules, blocked keywords, protected apps. Kept as a small private
 * file so it survives a database rebuild (corruption, or an older version
 * installed over a newer one). Never contains logs or statistics.
 */
data class UserConfig(
    val rules: List<UserRuleEntry>,
    val keywords: List<KeywordEntry>,
    val protectedApps: List<String>,
) {
    val isEmpty get() = rules.isEmpty() && keywords.isEmpty() && protectedApps.isEmpty()
}

data class UserRuleEntry(val domain: String, val action: RuleAction, val category: Category, val includeSubdomains: Boolean)

data class KeywordEntry(val phrase: String, val category: Category)

/**
 * Line format, strictly validated on read (a bad line is skipped, never
 * trusted): `sgbackup 1`, then `r<TAB>B|A<TAB>domain<TAB>category<TAB>0|1`,
 * `k<TAB>category<TAB>phrase`, `a<TAB>package`.
 */
object UserConfigBackup {
    private const val HEADER = "sgbackup 1"
    const val MAX_ENTRIES = 10_000
    private val packagePattern = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")

    fun encode(c: UserConfig): String = buildString {
        appendLine(HEADER)
        for (r in c.rules) {
            appendLine("r\t${if (r.action == RuleAction.BLOCK) "B" else "A"}\t${r.domain}\t${r.category.id}\t${if (r.includeSubdomains) 1 else 0}")
        }
        for (k in c.keywords) {
            if ('\t' in k.phrase || '\n' in k.phrase) continue
            appendLine("k\t${k.category.id}\t${k.phrase}")
        }
        for (a in c.protectedApps) appendLine("a\t$a")
    }

    /** Returns null for anything that isn't a backup at all. */
    fun decode(text: String): UserConfig? {
        val lines = text.split('\n')
        if (lines.firstOrNull()?.trimEnd('\r') != HEADER) return null
        val rules = ArrayList<UserRuleEntry>()
        val keywords = ArrayList<KeywordEntry>()
        val apps = ArrayList<String>()
        for (raw in lines.drop(1).take(MAX_ENTRIES)) {
            val f = raw.trimEnd('\r').split('\t')
            when (f.firstOrNull()) {
                "r" -> if (f.size == 5) {
                    val action = when (f[1]) { "B" -> RuleAction.BLOCK; "A" -> RuleAction.ALLOW; else -> null }
                    val domain = DomainName.parseRuleDomain(f[2])
                    val category = Category.fromId(f[3])
                    if (action != null && domain != null && category != null && f[4] in setOf("0", "1")) {
                        rules += UserRuleEntry(domain, action, category, f[4] == "1")
                    }
                }
                "k" -> if (f.size == 3) {
                    val category = Category.fromId(f[1])
                    val phrase = f[2].trim()
                    if (category != null && category.isUserAssignable && phrase.length in 3..200) {
                        keywords += KeywordEntry(phrase, category)
                    }
                }
                "a" -> if (f.size == 2 && packagePattern.matches(f[1]) && f[1].length <= 255) apps += f[1]
            }
        }
        return UserConfig(rules.distinctBy { it.domain to it.action }, keywords.distinctBy { it.phrase }, apps.distinct())
    }
}
