package com.safeguard.app.engine.rules

/**
 * Content categories. [id] is the stable identifier shared with Flutter
 * and stored in the database; it must never change once shipped.
 */
enum class Category(val id: String) {
    SEXUAL("sexual"),
    VIOLENCE("violence"),
    GORE("gore"),
    GAMBLING("gambling"),
    DRUGS("drugs"),
    DANGEROUS("dangerous"),
    SAFE("safe"),
    UNKNOWN("unknown");

    /** Whether the user can switch filtering of this category on or off. */
    val isFilterable: Boolean get() = this != SAFE && this != UNKNOWN

    companion object {
        fun fromId(id: String?): Category? = entries.firstOrNull { it.id == id }
        val filterable: List<Category> get() = entries.filter { it.isFilterable }
    }
}

enum class RuleAction { ALLOW, BLOCK }

/** Where a rule came from. Precedence is decided by the engine, not here. */
enum class RuleSource(val id: String) {
    /** Shipped with the app. */
    BUILT_IN("built_in"),

    /** Added by the user (custom blocklist / allowlist). */
    USER("user"),

    /** Downloaded rule list (future: Phase 3). */
    REMOTE("remote"),

    /** Debug-only fixtures for manual testing on a device. */
    TEST("test");

    companion object {
        fun fromId(id: String?): RuleSource? = entries.firstOrNull { it.id == id }
    }
}

data class Rule(
    /** Normalised domain; also matches every subdomain. */
    val domain: String,
    val category: Category,
    val action: RuleAction,
    val enabled: Boolean = true,
    val source: RuleSource,
    /** Version of the list the rule came from (user rules: 1). */
    val version: Int = 1,
    /** Epoch millis of the last change. */
    val updatedAt: Long = 0L,
)
