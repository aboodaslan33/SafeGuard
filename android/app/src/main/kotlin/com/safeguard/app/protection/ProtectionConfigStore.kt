package com.safeguard.app.protection

import android.content.Context
import android.util.Base64
import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.ai.ThresholdProfiles
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.UnknownDomainPolicy
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.safesearch.YouTubeMode
import com.safeguard.app.engine.search.SearchPolicyConfig
import java.security.SecureRandom

/**
 * Native copy of the protection settings.
 *
 * Flutter owns the settings UI, but the VPN must keep working when Flutter
 * isn't running (after a reboot, after the app is swiped away), so every
 * change is mirrored here and the VPN reads only this store.
 */
class ProtectionConfigStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    @Volatile
    private var cached: ProtectionPolicy = read()

    val policy: ProtectionPolicy get() = cached

    /** Whether the user wants protection on (intent, not VPN state). */
    val enabled: Boolean get() = cached.enabled

    @Synchronized
    fun update(enabled: Boolean? = null, categories: Set<Category>? = null): ProtectionPolicy {
        val next = cached.copy(
            enabled = enabled ?: cached.enabled,
            blockedCategories = (categories ?: cached.blockedCategories).filter { it.isFilterable }.toSet(),
        )
        prefs.edit()
            .putBoolean(KEY_ENABLED, next.enabled)
            .putStringSet(KEY_CATEGORIES, next.blockedCategories.map { it.id }.toSet())
            .apply()
        cached = next
        return next
    }

    @Synchronized
    fun setCategory(category: Category, blocked: Boolean): ProtectionPolicy {
        val set = cached.blockedCategories.toMutableSet()
        if (blocked) set += category else set -= category
        return update(categories = set)
    }

    // ---- Search Protection (Phase 3) ------------------------------------

    @Volatile
    private var cachedSafeSearch: SafeSearchConfig = readSafeSearch()

    /** Master switch for SafeSearch enforcement + query classification. */
    val searchProtectionEnabled: Boolean get() = cachedSafeSearch.enabled

    /** Effective SafeSearch config (off when protection or search protection is off). */
    val safeSearch: SafeSearchConfig
        get() = if (cached.enabled) cachedSafeSearch else SafeSearchConfig.OFF

    val rawSafeSearch: SafeSearchConfig get() = cachedSafeSearch

    /** Search policy: shares the DNS categories; off when protection is off. */
    val searchPolicy: SearchPolicyConfig
        get() = if (cached.enabled && cachedSafeSearch.enabled) {
            SearchPolicyConfig(true, cached.blockedCategories)
        } else {
            SearchPolicyConfig.DISABLED
        }

    @Synchronized
    fun updateSearch(config: SafeSearchConfig): SafeSearchConfig {
        prefs.edit()
            .putBoolean(KEY_SEARCH, config.enabled)
            .putBoolean(KEY_SS_GOOGLE, config.google)
            .putBoolean(KEY_SS_BING, config.bing)
            .putBoolean(KEY_SS_DDG, config.duckDuckGo)
            .putString(KEY_SS_YOUTUBE, config.youtube.id)
            .apply()
        cachedSafeSearch = config
        return config
    }

    // ---- AI Protection (Phase 4) -----------------------------------------

    @Volatile
    private var cachedAi: AiSettings = readAi()

    /** As the user set it. */
    val rawAi: AiSettings get() = cachedAi

    @Synchronized
    fun updateAi(next: AiSettings): AiSettings {
        val clean = next.copy(
            customThresholds = next.customThresholds
                .filterKeys { it.isFilterable }
                .mapValues { ThresholdProfiles.clampCustom(it.value) },
        )
        val editor = prefs.edit()
            .putBoolean(KEY_AI_ENABLED, clean.enabled)
            .putString(KEY_AI_MODE, clean.mode.id)
        for (c in Category.filterable) {
            val v = clean.customThresholds[c]
            if (v == null) editor.remove(KEY_AI_THRESHOLD + c.id) else editor.putFloat(KEY_AI_THRESHOLD + c.id, v.toFloat())
        }
        editor.apply()
        cachedAi = clean
        return clean
    }

    private fun readAi() = AiSettings(
        // On-device only and on-demand, so on by default like the categories.
        enabled = prefs.getBoolean(KEY_AI_ENABLED, true),
        mode = DetectionMode.fromId(prefs.getString(KEY_AI_MODE, null)),
        customThresholds = Category.filterable
            .filter { prefs.contains(KEY_AI_THRESHOLD + it.id) }
            .associateWith { ThresholdProfiles.clampCustom(prefs.getFloat(KEY_AI_THRESHOLD + it.id, 0.9f).toDouble()) },
    )

    var accessibilityDisclosureDeclined: Boolean
        get() = prefs.getBoolean(KEY_A11Y_DECLINED, false)
        set(value) = prefs.edit().putBoolean(KEY_A11Y_DECLINED, value).apply()

    /**
     * Per-install random key for search-event hashes. Generated on first
     * use, never leaves the device, deleted by [clear].
     */
    @Synchronized
    fun hashKey(): ByteArray {
        prefs.getString(KEY_HASH, null)?.let { return Base64.decode(it, Base64.NO_WRAP) }
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString(KEY_HASH, Base64.encodeToString(key, Base64.NO_WRAP)).apply()
        return key
    }

    private fun readSafeSearch() = SafeSearchConfig(
        // Search protection follows the Phase 1 "فلترة البحث" preference; on by default.
        enabled = prefs.getBoolean(KEY_SEARCH, true),
        google = prefs.getBoolean(KEY_SS_GOOGLE, true),
        bing = prefs.getBoolean(KEY_SS_BING, true),
        duckDuckGo = prefs.getBoolean(KEY_SS_DDG, true),
        youtube = YouTubeMode.fromId(prefs.getString(KEY_SS_YOUTUBE, null)),
    )

    fun clear() {
        prefs.edit().clear().apply()
        cached = read()
        cachedSafeSearch = readSafeSearch()
        cachedAi = readAi()
    }

    private fun read(): ProtectionPolicy {
        // Secure default before Flutter has ever synced: all categories on,
        // protection off until the user turns it on (VPN needs consent).
        val ids = prefs.getStringSet(KEY_CATEGORIES, null)
        val categories = ids?.mapNotNull(Category::fromId)?.toSet() ?: Category.filterable.toSet()
        return ProtectionPolicy(
            enabled = prefs.getBoolean(KEY_ENABLED, false),
            blockedCategories = categories,
            // Strict Mode is not exposed yet; unknown domains are allowed.
            unknownDomains = UnknownDomainPolicy.ALLOW,
        )
    }

    private companion object {
        const val NAME = "safeguard_protection"
        const val KEY_ENABLED = "enabled"
        const val KEY_CATEGORIES = "blocked_categories"
        const val KEY_SEARCH = "search_protection"
        const val KEY_SS_GOOGLE = "safesearch_google"
        const val KEY_SS_BING = "safesearch_bing"
        const val KEY_SS_DDG = "safesearch_ddg"
        const val KEY_SS_YOUTUBE = "safesearch_youtube"
        const val KEY_A11Y_DECLINED = "a11y_disclosure_declined"
        const val KEY_HASH = "event_hash_key"
        const val KEY_AI_ENABLED = "ai_enabled"
        const val KEY_AI_MODE = "ai_mode"
        const val KEY_AI_THRESHOLD = "ai_threshold_"
    }
}
