package com.safeguard.app.protection

import android.content.Context
import android.os.SystemClock
import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.ai.ThresholdProfiles
import com.safeguard.app.engine.health.Incident
import com.safeguard.app.engine.health.IncidentKind
import com.safeguard.app.engine.health.IncidentLog
import com.safeguard.app.engine.logging.LogRetention
import com.safeguard.app.engine.modes.EffectiveSettings
import com.safeguard.app.engine.modes.ProtectionMode
import com.safeguard.app.engine.modes.ProtectionModes
import com.safeguard.app.engine.modes.UserSettings
import com.safeguard.app.engine.pause.TemporaryUnlock
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.UnknownDomainPolicy
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.safesearch.YouTubeMode
import com.safeguard.app.engine.search.SearchPolicyConfig

/**
 * Native copy of the protection settings.
 *
 * Flutter owns the settings UI, but the VPN must keep working when Flutter
 * isn't running (after a reboot, after the app is swiped away), so every
 * change is mirrored here and the VPN reads only this store.
 *
 * Two layers: what the user set (`raw*`, [userPolicy]) and what is enforced
 * ([policy], [safeSearch], [searchPolicy], [effectiveAi]), resolved from the
 * [mode] and switched off during a temporary unlock or Safe Mode.
 */
class ProtectionConfigStore(
    context: Context,
    private val wallClock: () -> Long = System::currentTimeMillis,
    private val elapsedClock: () -> Long = SystemClock::elapsedRealtime,
) {
    private val prefs = context.applicationContext.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    @Volatile private var cached: ProtectionPolicy = read()
    @Volatile private var cachedSafeSearch: SafeSearchConfig = readSafeSearch()
    @Volatile private var cachedAi: AiSettings = readAi()
    @Volatile private var cachedMode: ProtectionMode = ProtectionMode.fromId(prefs.getString(KEY_MODE, null))
    @Volatile private var cachedPause: TemporaryUnlock? = readPause()
    @Volatile private var effective: EffectiveSettings = resolve()

    // ---- User intent -------------------------------------------------------

    /** Whether the user wants protection on (intent, not VPN state). */
    val enabled: Boolean get() = cached.enabled

    /** Categories as the user set them (used in CUSTOM mode). */
    val userPolicy: ProtectionPolicy get() = cached

    val mode: ProtectionMode get() = cachedMode

    // ---- Enforced ------------------------------------------------------------

    /** False while protection is off, paused, or in Safe Mode. */
    val filteringActive: Boolean get() = cached.enabled && !isPaused() && !safeMode

    /** What the DNS filter enforces (mode-resolved categories). */
    val policy: ProtectionPolicy
        get() = ProtectionPolicy(filteringActive, effective.categories, UnknownDomainPolicy.ALLOW)

    val effectiveCategories: Set<Category> get() = effective.categories

    /** Effective SafeSearch config (off when protection or search protection is off). */
    val safeSearch: SafeSearchConfig
        get() = if (filteringActive && effective.safeSearch.enabled) effective.safeSearch else SafeSearchConfig.OFF

    /** Search policy: shares the DNS categories; the lexicon threshold follows the mode. */
    val searchPolicy: SearchPolicyConfig
        get() = if (filteringActive && effective.safeSearch.enabled) {
            SearchPolicyConfig(true, effective.categories, defaultThreshold = effective.lexiconThreshold)
        } else {
            SearchPolicyConfig.DISABLED
        }

    val searchEffectivelyEnabled: Boolean get() = effective.safeSearch.enabled

    val effectiveAi: AiSettings get() = effective.ai

    @Synchronized
    fun update(enabled: Boolean? = null, categories: Set<Category>? = null, mode: ProtectionMode? = null): ProtectionPolicy {
        val next = cached.copy(
            enabled = enabled ?: cached.enabled,
            blockedCategories = (categories ?: cached.blockedCategories).filter { it.isFilterable }.toSet(),
        )
        val editor = prefs.edit()
            .putBoolean(KEY_ENABLED, next.enabled)
            .putStringSet(KEY_CATEGORIES, next.blockedCategories.map { it.id }.toSet())
        if (mode != null) editor.putString(KEY_MODE, mode.id)
        editor.apply()
        cached = next
        if (mode != null) cachedMode = mode
        effective = resolve()
        return next
    }

    @Synchronized
    fun setCategory(category: Category, blocked: Boolean): ProtectionPolicy {
        val set = cached.blockedCategories.toMutableSet()
        if (blocked) set += category else set -= category
        return update(categories = set)
    }

    // ---- Search Protection (Phase 3) ------------------------------------

    /** The user's search switch (CUSTOM mode). */
    val searchProtectionEnabled: Boolean get() = cachedSafeSearch.enabled

    val rawSafeSearch: SafeSearchConfig get() = cachedSafeSearch

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
        effective = resolve()
        return config
    }

    // ---- AI Protection (Phase 4) -----------------------------------------

    /** As the user set it (CUSTOM mode). */
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
        effective = resolve()
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

    // ---- Temporary unlock (Phase 5) -----------------------------------

    fun isPaused(): Boolean = cachedPause?.isActive(wallClock(), elapsedClock()) == true

    val pause: TemporaryUnlock? get() = cachedPause?.takeIf { it.isActive(wallClock(), elapsedClock()) }

    fun pauseRemainingMs(): Long = cachedPause?.remainingMs(wallClock(), elapsedClock()) ?: 0

    @Synchronized
    fun startPause(minutes: Int): TemporaryUnlock {
        val p = TemporaryUnlock.start(minutes, wallClock(), elapsedClock())
        prefs.edit()
            .putLong(KEY_PAUSE_WALL, p.startedAtWall)
            .putLong(KEY_PAUSE_ELAPSED, p.startedAtElapsed)
            .putLong(KEY_PAUSE_DURATION, p.durationMs)
            .apply()
        cachedPause = p
        return p
    }

    @Synchronized
    fun endPause() {
        prefs.edit().remove(KEY_PAUSE_WALL).remove(KEY_PAUSE_ELAPSED).remove(KEY_PAUSE_DURATION).apply()
        cachedPause = null
    }

    private fun readPause(): TemporaryUnlock? {
        if (!prefs.contains(KEY_PAUSE_DURATION)) return null
        return try {
            TemporaryUnlock(
                prefs.getLong(KEY_PAUSE_WALL, 0),
                prefs.getLong(KEY_PAUSE_ELAPSED, 0),
                prefs.getLong(KEY_PAUSE_DURATION, 0),
            )
        } catch (e: IllegalArgumentException) {
            null // corrupt value: no pause (fail closed)
        }
    }

    // ---- Safe Mode, boot, incidents (Phase 5) ----------------------------

    /** Chosen by the user; blocks every automatic start until they re-enable protection. */
    /** Activity-log retention (Phase 6 privacy setting). */
    var logRetention: LogRetention
        get() = LogRetention.fromId(prefs.getString(KEY_LOG_RETENTION, null)) ?: LogRetention.DEFAULT
        set(value) = prefs.edit().putString(KEY_LOG_RETENTION, value.id).apply()

    /** Notify when protection is degraded or stops (on by default). */
    var alertsEnabled: Boolean
        get() = prefs.getBoolean(KEY_ALERTS, true)
        set(value) = prefs.edit().putBoolean(KEY_ALERTS, value).apply()

    /** UI language chosen in Flutter ("ar" or "en"), for native screens. */
    var uiLanguage: String
        get() = prefs.getString(KEY_UI_LANGUAGE, null) ?: "ar"
        set(value) = prefs.edit().putString(KEY_UI_LANGUAGE, value).apply()

    var safeMode: Boolean
        get() = prefs.getBoolean(KEY_SAFE_MODE, false)
        set(value) = prefs.edit().putBoolean(KEY_SAFE_MODE, value).apply()

    /** Last boot/update start attempt: result id + time. */
    fun recordBoot(result: String, at: Long) {
        prefs.edit().putString(KEY_BOOT_RESULT, result).putLong(KEY_BOOT_AT, at).apply()
    }

    val lastBoot: Pair<String, Long>?
        get() = prefs.getString(KEY_BOOT_RESULT, null)?.let { it to prefs.getLong(KEY_BOOT_AT, 0) }

    var accessibilityWasEnabled: Boolean
        get() = prefs.getBoolean(KEY_A11Y_WAS_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_A11Y_WAS_ENABLED, value).apply()

    val incidents = IncidentLog().also { log ->
        val stored = prefs.getString(KEY_INCIDENTS, "").orEmpty().split(';').mapNotNull { item ->
            val (ts, kind) = item.split(':').takeIf { it.size == 2 } ?: return@mapNotNull null
            val k = IncidentKind.fromId(kind) ?: return@mapNotNull null
            ts.toLongOrNull()?.let { Incident(it, k) }
        }
        log.restore(stored, prefs.getLong(KEY_INCIDENTS_ACK, 0))
    }

    @Synchronized
    fun addIncident(incident: Incident) {
        incidents.add(incident)
        persistIncidents()
    }

    @Synchronized
    fun acknowledgeIncidents(upTo: Long) {
        incidents.acknowledge(upTo)
        persistIncidents()
    }

    private fun persistIncidents() {
        prefs.edit()
            .putString(KEY_INCIDENTS, incidents.all().joinToString(";") { "${it.timestamp}:${it.kind.id}" })
            .putLong(KEY_INCIDENTS_ACK, incidents.acknowledgedUpTo)
            .apply()
    }

    var accessibilityDisclosureDeclined: Boolean
        get() = prefs.getBoolean(KEY_A11Y_DECLINED, false)
        set(value) = prefs.edit().putBoolean(KEY_A11Y_DECLINED, value).apply()

    private fun readSafeSearch() = SafeSearchConfig(
        // Search protection follows the Phase 1 "فلترة البحث" preference; on by default.
        enabled = prefs.getBoolean(KEY_SEARCH, true),
        google = prefs.getBoolean(KEY_SS_GOOGLE, true),
        bing = prefs.getBoolean(KEY_SS_BING, true),
        duckDuckGo = prefs.getBoolean(KEY_SS_DDG, true),
        youtube = YouTubeMode.fromId(prefs.getString(KEY_SS_YOUTUBE, null)),
    )

    /**
     * "Reset protection": secure defaults for every setting (CUSTOM mode with
     * all categories, search + AI defaults — as on a new install), pause and
     * Safe Mode ended. Keeps the
     * on/off intent, lists, keywords, protected apps, logs and the HMAC key.
     */
    @Synchronized
    fun resetSettings() {
        val editor = prefs.edit()
        listOf(KEY_CATEGORIES, KEY_SEARCH, KEY_SS_GOOGLE, KEY_SS_BING, KEY_SS_DDG, KEY_SS_YOUTUBE,
            KEY_AI_ENABLED, KEY_AI_MODE, KEY_SAFE_MODE, KEY_PAUSE_WALL, KEY_PAUSE_ELAPSED, KEY_PAUSE_DURATION,
        ).forEach { editor.remove(it) }
        Category.filterable.forEach { editor.remove(KEY_AI_THRESHOLD + it.id) }
        editor.putString(KEY_MODE, ProtectionMode.CUSTOM.id).apply()
        reload()
    }

    fun clear() {
        prefs.edit().clear().apply()
        reload()
    }

    private fun reload() {
        cached = read()
        cachedSafeSearch = readSafeSearch()
        cachedAi = readAi()
        cachedMode = ProtectionMode.fromId(prefs.getString(KEY_MODE, null))
        cachedPause = readPause()
        incidents.restore(emptyList(), 0)
        effective = resolve()
    }

    private fun resolve() = ProtectionModes.resolve(cachedMode, UserSettings(cached.blockedCategories, cachedSafeSearch, cachedAi))

    private fun read(): ProtectionPolicy {
        // Secure default before Flutter has ever synced: all categories on,
        // protection off until the user turns it on (VPN needs consent).
        val ids = prefs.getStringSet(KEY_CATEGORIES, null)
        val categories = ids?.mapNotNull(Category::fromId)?.toSet() ?: Category.filterable.toSet()
        return ProtectionPolicy(
            enabled = prefs.getBoolean(KEY_ENABLED, false),
            blockedCategories = categories,
            // Unknown domains are always allowed: blocking them would break
            // most of the web, even in STRICT mode.
            unknownDomains = UnknownDomainPolicy.ALLOW,
        )
    }

    private companion object {
        const val NAME = "safeguard_protection"
        const val KEY_ENABLED = "enabled"
        const val KEY_CATEGORIES = "blocked_categories"
        const val KEY_MODE = "protection_mode"
        const val KEY_SEARCH = "search_protection"
        const val KEY_SS_GOOGLE = "safesearch_google"
        const val KEY_SS_BING = "safesearch_bing"
        const val KEY_SS_DDG = "safesearch_ddg"
        const val KEY_SS_YOUTUBE = "safesearch_youtube"
        const val KEY_A11Y_DECLINED = "a11y_disclosure_declined"
        const val KEY_A11Y_WAS_ENABLED = "a11y_was_enabled"
        const val KEY_AI_ENABLED = "ai_enabled"
        const val KEY_AI_MODE = "ai_mode"
        const val KEY_AI_THRESHOLD = "ai_threshold_"
        const val KEY_PAUSE_WALL = "pause_wall"
        const val KEY_PAUSE_ELAPSED = "pause_elapsed"
        const val KEY_PAUSE_DURATION = "pause_duration"
        const val KEY_SAFE_MODE = "safe_mode"
        const val KEY_UI_LANGUAGE = "ui_language"
        const val KEY_ALERTS = "alerts_enabled"
        const val KEY_LOG_RETENTION = "log_retention"
        const val KEY_BOOT_RESULT = "boot_result"
        const val KEY_BOOT_AT = "boot_at"
        const val KEY_INCIDENTS = "incidents"
        const val KEY_INCIDENTS_ACK = "incidents_ack"
    }
}
