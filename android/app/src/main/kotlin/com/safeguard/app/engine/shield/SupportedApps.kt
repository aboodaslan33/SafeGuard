package com.safeguard.app.engine.shield

/** How SafeGuard can obtain content from an app. [id] goes to the UI. */
enum class AcquisitionMethod(val id: String) {
    /** Text exposed to accessibility services (captions, titles, web text). */
    ACCESSIBILITY_TEXT("accessibility_text"),

    /**
     * Screen frames via MediaProjection: Android's consent dialog and
     * capture indicator; runs only while the user allows it.
     */
    SCREEN_CAPTURE("screen_capture"),
}

/**
 * What SafeGuard expects to be able to read in an app, by design. None of
 * this has been verified on a real device ([SupportedApp.verifiedOnDevice]).
 */
enum class SupportLevel(val id: String) {
    /** Most visible text is exposed to accessibility (web pages, posts). */
    TEXT("text"),

    /** Only some text (captions, titles); most content is images or video. */
    TEXT_LIMITED("text_limited"),
}

/** Known reasons content may be missed. Stable ids; the UI translates them. */
enum class ShieldLimitation(val id: String) {
    /**
     * Photos and video are checked only while screen capture is on (the
     * user consents in Android's dialog; Android 14+ asks again after a
     * restart). Protected (DRM) video appears black and can't be checked.
     */
    IMAGES_NEED_CAPTURE("images_need_capture"),

    /** Mostly video; captions are the only text. */
    MOSTLY_VIDEO("mostly_video"),

    /** Custom-drawn UI may expose little or no text to accessibility. */
    CUSTOM_RENDERING("custom_rendering"),

    /** Apps can mark screens secure (FLAG_SECURE): not readable or capturable. */
    SECURE_SURFACES("secure_surfaces"),

    /** App updates can change what is exposed at any time. */
    UI_CHANGES("ui_changes"),

    /** Private messages shown in the app are processed like any visible text (memory only). */
    PRIVATE_MESSAGES_VISIBLE("private_messages_visible"),
}

data class SupportedApp(
    /** Stable key for settings (e.g. "tiktok"). */
    val key: String,
    val displayName: String,
    /** Every package id this app ships under (regional variants). */
    val packages: List<String>,
    val level: SupportLevel,
    val methods: List<AcquisitionMethod>,
    val limitations: List<ShieldLimitation>,
    /** True only after a real-device test run (docs/FINAL_AI_TESTING.md). */
    val verifiedOnDevice: Boolean = false,
)

/**
 * The apps the AI Content Shield may inspect. Nothing outside this list is
 * ever read: the accessibility service is limited to these package ids at
 * the system level (`AccessibilityServiceInfo.packageNames`). Adding an app
 * is a data change here; the engine doesn't know app names.
 */
object SupportedApps {
    private val common = listOf(ShieldLimitation.IMAGES_NEED_CAPTURE, ShieldLimitation.SECURE_SURFACES, ShieldLimitation.UI_CHANGES)
    private val both = listOf(AcquisitionMethod.ACCESSIBILITY_TEXT, AcquisitionMethod.SCREEN_CAPTURE)

    val all: List<SupportedApp> = listOf(
        SupportedApp(
            "instagram", "Instagram", listOf("com.instagram.android"), SupportLevel.TEXT_LIMITED, both,
            common + ShieldLimitation.CUSTOM_RENDERING + ShieldLimitation.PRIVATE_MESSAGES_VISIBLE,
        ),
        SupportedApp(
            "tiktok", "TikTok", listOf("com.zhiliaoapp.musically", "com.ss.android.ugc.trill"), SupportLevel.TEXT_LIMITED, both,
            common + ShieldLimitation.MOSTLY_VIDEO + ShieldLimitation.CUSTOM_RENDERING + ShieldLimitation.PRIVATE_MESSAGES_VISIBLE,
        ),
        SupportedApp(
            "youtube", "YouTube", listOf("com.google.android.youtube"), SupportLevel.TEXT_LIMITED, both,
            common + ShieldLimitation.MOSTLY_VIDEO,
        ),
        SupportedApp(
            "reddit", "Reddit", listOf("com.reddit.frontpage"), SupportLevel.TEXT, both,
            common + ShieldLimitation.PRIVATE_MESSAGES_VISIBLE,
        ),
        SupportedApp(
            "facebook", "Facebook", listOf("com.facebook.katana", "com.facebook.lite"), SupportLevel.TEXT_LIMITED, both,
            common + ShieldLimitation.CUSTOM_RENDERING + ShieldLimitation.PRIVATE_MESSAGES_VISIBLE,
        ),
        SupportedApp("chrome", "Chrome", listOf("com.android.chrome"), SupportLevel.TEXT, both, common),
        SupportedApp("firefox", "Firefox", listOf("org.mozilla.firefox"), SupportLevel.TEXT, both, common),
    )

    private val byPackage: Map<String, SupportedApp> = all.flatMap { a -> a.packages.map { it to a } }.toMap()

    init {
        require(all.map { it.key }.toSet().size == all.size) { "duplicate key" }
        require(byPackage.size == all.sumOf { it.packages.size }) { "package listed twice" }
    }

    fun forPackage(pkg: String?): SupportedApp? = pkg?.let(byPackage::get)

    fun byKey(key: String): SupportedApp? = all.firstOrNull { it.key == key }

    val allPackages: List<String> get() = byPackage.keys.sorted()
}
