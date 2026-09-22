package com.safeguard.app.engine.safesearch

enum class YouTubeMode(val id: String) {
    OFF("off"),

    /** Restricted Mode (moderate): restrictmoderate.youtube.com */
    MODERATE("moderate"),

    /** Restricted Mode (strict): restrict.youtube.com */
    STRICT("strict");

    companion object {
        fun fromId(id: String?) = entries.firstOrNull { it.id == id } ?: STRICT
    }
}

/**
 * Which engines get SafeSearch enforced. Applies only while Search
 * Protection is on and the VPN is running.
 */
data class SafeSearchConfig(
    val enabled: Boolean,
    val google: Boolean = true,
    val bing: Boolean = true,
    val duckDuckGo: Boolean = true,
    val youtube: YouTubeMode = YouTubeMode.STRICT,
) {
    companion object {
        val OFF = SafeSearchConfig(enabled = false)
    }
}

/**
 * Maps search-engine hostnames to the engines' *official* SafeSearch
 * endpoints. This is the mechanism each provider documents for networks
 * that want to enforce SafeSearch (a DNS CNAME), not a bypass of anything:
 *
 * - Google: forcesafesearch.google.com
 * - Bing: strict.bing.com
 * - DuckDuckGo: safe.duckduckgo.com
 * - YouTube: restrict.youtube.com / restrictmoderate.youtube.com
 *
 * Only the search front-ends are mapped; mail.google.com, maps, APIs other
 * than YouTube's, etc. are never touched.
 */
object SafeSearchRewriter {
    const val GOOGLE_TARGET = "forcesafesearch.google.com"
    const val BING_TARGET = "strict.bing.com"
    const val DDG_TARGET = "safe.duckduckgo.com"
    const val YOUTUBE_STRICT_TARGET = "restrict.youtube.com"
    const val YOUTUBE_MODERATE_TARGET = "restrictmoderate.youtube.com"

    // google.com, google.de, google.com.sa, google.co.uk — with or without www.
    private val googleSearch = Regex("^(www\\.)?google\\.(com|[a-z]{2}|com\\.[a-z]{2}|co\\.[a-z]{2})$")
    private val bing = setOf("bing.com", "www.bing.com")
    private val duckDuckGo = setOf("duckduckgo.com", "www.duckduckgo.com", "start.duckduckgo.com")
    private val youtube = setOf(
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "youtubei.googleapis.com", "youtube.googleapis.com", "www.youtube-nocookie.com",
    )

    /** The SafeSearch hostname to answer [name] with, or null to leave it alone. */
    fun targetFor(name: String, config: SafeSearchConfig): String? {
        if (!config.enabled) return null
        return when {
            config.google && googleSearch.matches(name) -> GOOGLE_TARGET
            config.bing && name in bing -> BING_TARGET
            config.duckDuckGo && name in duckDuckGo -> DDG_TARGET
            name in youtube -> when (config.youtube) {
                YouTubeMode.OFF -> null
                YouTubeMode.MODERATE -> YOUTUBE_MODERATE_TARGET
                YouTubeMode.STRICT -> YOUTUBE_STRICT_TARGET
            }
            else -> null
        }
    }
}
