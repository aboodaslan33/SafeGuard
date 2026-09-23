package com.safeguard.app.engine.modes

import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.safesearch.YouTubeMode
import com.safeguard.app.engine.search.SearchPolicyConfig

/** Global protection mode. [id] is stored; never rename. */
enum class ProtectionMode(val id: String) {
    /** Blocks on high confidence; fewer false positives. */
    NORMAL("normal"),

    /** Everything on, lower thresholds: less access, more false positives. */
    STRICT("strict"),

    /** The user's own categories, thresholds, search and AI settings. */
    CUSTOM("custom");

    companion object {
        /** Unknown/missing → CUSTOM, so settings stored before modes existed keep working. */
        fun fromId(id: String?) = entries.firstOrNull { it.id == id } ?: CUSTOM
    }
}

/** What the user configured (used as-is in CUSTOM mode). */
data class UserSettings(
    val categories: Set<Category>,
    val safeSearch: SafeSearchConfig,
    val ai: AiSettings,
)

/** What is actually enforced. */
data class EffectiveSettings(
    val categories: Set<Category>,
    val safeSearch: SafeSearchConfig,
    /** Score at which the Phase 3 search lexicon blocks. */
    val lexiconThreshold: Double,
    val ai: AiSettings,
)

/**
 * NORMAL and STRICT are fixed presets; CUSTOM passes the user's settings
 * through. Custom lists, keywords and protected apps apply in every mode.
 */
object ProtectionModes {
    const val NORMAL_LEXICON_THRESHOLD = SearchPolicyConfig.DEFAULT_THRESHOLD
    const val STRICT_LEXICON_THRESHOLD = 0.45

    fun resolve(mode: ProtectionMode, user: UserSettings): EffectiveSettings = when (mode) {
        ProtectionMode.NORMAL -> EffectiveSettings(
            categories = Category.filterable.toSet(),
            safeSearch = SafeSearchConfig(true, google = true, bing = true, duckDuckGo = true, youtube = YouTubeMode.MODERATE),
            lexiconThreshold = NORMAL_LEXICON_THRESHOLD,
            ai = AiSettings(enabled = true, mode = DetectionMode.NORMAL),
        )
        ProtectionMode.STRICT -> EffectiveSettings(
            categories = Category.filterable.toSet(),
            safeSearch = SafeSearchConfig(true, google = true, bing = true, duckDuckGo = true, youtube = YouTubeMode.STRICT),
            lexiconThreshold = STRICT_LEXICON_THRESHOLD,
            ai = AiSettings(enabled = true, mode = DetectionMode.STRICT),
        )
        ProtectionMode.CUSTOM -> EffectiveSettings(
            categories = user.categories.filter { it.isFilterable }.toSet(),
            safeSearch = user.safeSearch,
            lexiconThreshold = NORMAL_LEXICON_THRESHOLD,
            ai = user.ai,
        )
    }

    /** Mode changes that need the PIN: everything except NORMAL → STRICT (and no-ops). */
    fun changeNeedsPin(from: ProtectionMode, to: ProtectionMode): Boolean =
        from != to && !(from == ProtectionMode.NORMAL && to == ProtectionMode.STRICT)
}
