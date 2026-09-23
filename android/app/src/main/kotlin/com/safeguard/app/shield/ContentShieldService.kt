package com.safeguard.app.shield

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.shield.BlockAction
import com.safeguard.app.engine.shield.BlockEscalation
import com.safeguard.app.engine.shield.NodeView
import com.safeguard.app.engine.shield.SearchFieldDetector
import com.safeguard.app.engine.shield.ShieldOutcome
import com.safeguard.app.engine.shield.SupportedApps
import com.safeguard.app.engine.shield.VisibleTextExtractor
import com.safeguard.app.protection.ProtectionManager
import java.lang.ref.WeakReference
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * AI Content Shield: reads the text that supported apps show on screen and
 * hands it to the on-device classifier; SafeGuard's policy engine decides.
 *
 * Least privilege, enforced by the system and by this class:
 * - Events come only from the supported apps' package ids
 *   (`packageNames`, set here from [SupportedApps] and the user's per-app
 *   switches); SafeGuard never receives events from any other app.
 * - While the shield or protection is off, content events are switched off
 *   and no window content is read.
 * - Password fields are never read. Editable fields are never read, with
 *   one exception: the focused search box of a supported app
 *   ([SearchFieldDetector]), checked by search protection once typing
 *   pauses. Message boxes and other inputs are not search boxes.
 *   Codes, numbers, e-mails and links are dropped ([VisibleTextExtractor]).
 * - Text is classified in memory on a background thread and discarded; it
 *   is never logged, stored or sent. Only block metadata (and, for a
 *   blocked search, a keyed hash) is logged.
 * - A block never leaves the app: SafeGuard covers the screen
 *   ([ShieldCover], an accessibility overlay showing only its own message)
 *   and swipes to the next item (reels, shorts, feeds). If blocked content
 *   keeps coming back, the cover stays until the user picks "Next" or
 *   "Back" ([BlockEscalation]). The only gestures performed are that one
 *   swipe and Back; a blocked search is cleared.
 * - Screen images come only from [ScreenCaptureService] (MediaProjection,
 *   with Android's consent); this service takes no screenshots.
 *
 * Separate from [com.safeguard.app.apps.AppGuardService] (app protection)
 * so the user grants each permission for its own purpose.
 */
class ContentShieldService : AccessibilityService() {

    private val manager by lazy { ProtectionManager.get(this) }
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "sg-shield").apply { isDaemon = true } }
    private val busy = AtomicBoolean(false)
    private val escalation = BlockEscalation()
    @Volatile private var destroyed = false
    @Volatile private var foreground: String? = null
    private var retried = false

    /** Last search-box query checked (so the same query isn't re-checked). */
    private var lastQuery: String? = null
    private var coverHiddenAt = Long.MIN_VALUE / 2

    private val cover by lazy {
        ShieldCover(
            service = this,
            arabic = { manager.config.uiLanguage != "en" },
            onNext = {
                escalation.reset()
                main.postDelayed({ swipeToNext() }, GESTURE_DELAY_MS)
            },
            onBack = {
                escalation.reset()
                performGlobalAction(GLOBAL_ACTION_BACK)
            },
            onHidden = {
                coverHiddenAt = SystemClock.uptimeMillis()
                // The screen underneath may have changed: let it settle before checking again.
                manager.shield.onContentChanged()
            },
        )
    }

    private val snapshot = Runnable { takeSnapshot() }

    override fun onServiceConnected() {
        instance = WeakReference(this)
        applyConfig()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return
        // SafeGuard's own cover is not "the app in front".
        if (pkg == packageName && (cover.showing || SystemClock.uptimeMillis() - coverHiddenAt < OWN_WINDOW_GRACE_MS)) return
        // Events from other apps arrive only with "all apps" on (packageNames
        // unset); they are used for the foreground app, never for text.
        val supported = SupportedApps.forPackage(pkg) != null
        val engine = manager.shield
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                // The keyboard isn't "the app in front".
                if (pkg != foreground && pkg != keyboardPackage()) {
                    // The user left the app: the cover belongs to it.
                    cover.hide()
                    lastQuery = null
                    foreground = pkg
                    manager.shieldForeground = pkg
                    engine.onForeground(pkg)
                    ScreenCaptureService.updateActive()
                }
            }
            else -> if (pkg == foreground) engine.onContentChanged()
        }
        if (!supported || !engine.isActiveFor(pkg)) {
            main.removeCallbacks(snapshot)
            return
        }
        retried = false
        main.removeCallbacks(snapshot)
        main.postDelayed(snapshot, SETTLE_MS)
    }

    private fun takeSnapshot() {
        val pkg = foreground ?: return
        val engine = manager.shield
        // Covered: the user can't see the content, nothing to check.
        if (cover.showing) return
        val root = rootInActiveWindow ?: return
        val text = try {
            if (root.packageName?.toString() != pkg) return
            checkSearch(root, pkg)
            if (busy.get()) return reschedule()
            if (!engine.wantsText(pkg)) return reschedule()
            VisibleTextExtractor.extract(root, Nodes)
        } catch (e: RuntimeException) {
            return // window changed while reading
        } finally {
            Nodes.recycleRoot(root)
        }
        if (text.isBlank() || !busy.compareAndSet(false, true)) return
        try {
            worker.execute {
                try {
                    val outcome = engine.onText(pkg, text)
                    if (outcome is ShieldOutcome.Blocked) main.post { act(outcome) }
                } finally {
                    busy.set(false)
                }
            }
        } catch (e: RejectedExecutionException) {
            busy.set(false) // service is shutting down
        }
    }

    /** One more try when throttled, so a settled screen is still checked. */
    private fun reschedule() {
        if (retried) return
        retried = true
        main.postDelayed(snapshot, RETRY_MS)
    }

    /**
     * The focused search box, if the app shows one: its query is checked by
     * search protection once typing pauses (this runs [SETTLE_MS] after the
     * last event). Any other field is left alone.
     */
    private fun checkSearch(root: AccessibilityNodeInfo, pkg: String) {
        val node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        val query = try {
            node?.let { searchQuery(it) }
        } finally {
            node?.let(Nodes::recycleRoot)
        }
        if (query == null) {
            lastQuery = null
            return
        }
        if (query == lastQuery) return
        lastQuery = query
        try {
            worker.execute {
                val d = manager.shieldSearch(pkg, query) ?: return@execute
                if (d.action == RuleAction.BLOCK) main.post { onSearchBlocked(pkg) }
            }
        } catch (e: RejectedExecutionException) {
            // service is shutting down
        }
    }

    private fun searchQuery(n: AccessibilityNodeInfo): String? {
        if (!n.isEditable || n.isPassword) return null
        val hint = if (Build.VERSION.SDK_INT >= 26) n.hintText else null
        if (!SearchFieldDetector.isSearchField(n.viewIdResourceName, hint, n.contentDescription, n.className)) return null
        val showingHint = if (Build.VERSION.SDK_INT >= 26) n.isShowingHintText else false
        return SearchFieldDetector.query(n.text, showingHint || (hint != null && n.text?.toString() == hint.toString()))
    }

    /** A blocked search: clear the box and say why. Stays in the app. */
    private fun onSearchBlocked(pkg: String) {
        if (destroyed || pkg != foreground) return
        val cleared = rootInActiveWindow?.let { root ->
            try {
                root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.let { n ->
                    try {
                        n.isEditable && !n.isPassword && n.performAction(
                            AccessibilityNodeInfo.ACTION_SET_TEXT,
                            Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "") },
                        )
                    } finally {
                        Nodes.recycleRoot(n)
                    }
                }
            } finally {
                Nodes.recycleRoot(root)
            }
        } ?: false
        lastQuery = null
        cover.flash(ShieldCover.Message.SEARCH, SEARCH_COVER_MS)
        // Couldn't clear it: leave the search screen (still inside the app).
        if (!cleared) performGlobalAction(GLOBAL_ACTION_BACK)
    }

    /** Hides blocked content without leaving the app: cover + skip, or a cover that stays. */
    private fun act(outcome: ShieldOutcome.Blocked) {
        val e = outcome.event
        if (destroyed || e.packageName != foreground || cover.showing) return
        val action = escalation.next(e.packageName, e.timestamp)
        if (!manager.onShieldBlock(e, action)) return
        manager.shield.onContentChanged() // the screen is about to change: let it settle
        when (action) {
            BlockAction.SKIP -> {
                // The cover doesn't take touches, so the swipe reaches the app underneath.
                cover.flash(ShieldCover.Message.CONTENT, SKIP_COVER_MS)
                main.postDelayed({
                    if (!destroyed && !swipeToNext()) cover.hold(ShieldCover.Message.CONTENT_REPEATED)
                }, GESTURE_DELAY_MS)
            }
            BlockAction.COVER -> cover.hold(ShieldCover.Message.CONTENT_REPEATED)
        }
    }

    /** One upward swipe in the middle of the screen: the next reel / short / feed item. */
    private fun swipeToNext(): Boolean {
        val m = resources.displayMetrics
        val x = m.widthPixels / 2f
        val path = Path().apply {
            moveTo(x, m.heightPixels * 0.72f)
            lineTo(x, m.heightPixels * 0.22f)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, SWIPE_MS))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    /**
     * Applies the current settings at the system level: which packages send
     * events, and whether content events are delivered at all.
     */
    fun applyConfig() {
        val info = serviceInfo ?: return
        val packages = manager.shieldPackages()
        val active = packages.isNotEmpty() && manager.shieldContentActive()
        // Never null: a null list would mean "every app".
        // Never null unless the user turned on "all apps" (image checks
        // everywhere): a null list means events from every app.
        info.packageNames = if (manager.config.shieldSettings.watchesAllApps) null else (packages.ifEmpty { SupportedApps.allPackages }).toTypedArray()
        info.eventTypes = when {
            packages.isEmpty() -> 0 // shield off: no events at all
            active -> AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_SCROLLED or
                AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED
            // Protection off or paused: app switches only (no content), to notice when it resumes.
            else -> AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        }
        info.flags = AccessibilityServiceInfo.DEFAULT
        serviceInfo = info
        if (!active) {
            main.removeCallbacks(snapshot)
            cover.hide()
            lastQuery = null
            foreground = null
            manager.shieldForeground = null
            manager.shield.onForeground(null)
            escalation.reset()
        }
        ScreenCaptureService.updateActive()
    }

    /** Package of the current keyboard (input method), cached briefly. */
    private var keyboard: Pair<Long, String?>? = null

    private fun keyboardPackage(): String? {
        val now = android.os.SystemClock.elapsedRealtime()
        keyboard?.let { (at, pkg) -> if (now - at < 60_000) return pkg }
        val pkg = android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.substringBefore('/')
        keyboard = now to pkg
        return pkg
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        destroyed = true
        main.removeCallbacks(snapshot)
        cover.hide()
        worker.shutdownNow()
        instance = null
        super.onDestroy()
    }

    /** [AccessibilityNodeInfo] as a [NodeView]; recycles nodes on Android < 13. */
    private object Nodes : NodeView<AccessibilityNodeInfo> {
        override fun childCount(n: AccessibilityNodeInfo) = n.childCount
        override fun child(n: AccessibilityNodeInfo, i: Int): AccessibilityNodeInfo? = n.getChild(i)
        override fun text(n: AccessibilityNodeInfo): CharSequence? = n.text
        override fun description(n: AccessibilityNodeInfo): CharSequence? = n.contentDescription
        override fun isEditable(n: AccessibilityNodeInfo) = n.isEditable
        override fun isPassword(n: AccessibilityNodeInfo) = n.isPassword
        override fun isVisible(n: AccessibilityNodeInfo) = n.isVisibleToUser
        override fun release(n: AccessibilityNodeInfo) = recycleRoot(n)

        @Suppress("DEPRECATION")
        fun recycleRoot(n: AccessibilityNodeInfo) {
            // No-op (and deprecated) from API 33; required before it.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) n.recycle()
        }
    }

    companion object {
        private const val SETTLE_MS = 450L
        private const val RETRY_MS = 1_100L
        private const val SWIPE_MS = 180L
        private const val GESTURE_DELAY_MS = 60L
        private const val SKIP_COVER_MS = 1_000L
        private const val SEARCH_COVER_MS = 1_500L
        private const val OWN_WINDOW_GRACE_MS = 1_000L

        @Volatile private var instance: WeakReference<ContentShieldService>? = null

        /** Whether SafeGuard's cover is on screen (screen frames then show the cover, not the app). */
        val covering: Boolean get() = instance?.get()?.cover?.showing == true

        /** A block found by the image path (capture thread): act on the main thread. */
        fun onBlocked(outcome: ShieldOutcome.Blocked) {
            val s = instance?.get() ?: return
            s.main.post { s.act(outcome) }
        }

        /** Re-applies settings to the running service (if the user enabled it). */
        fun refresh() {
            val s = instance?.get() ?: return
            s.main.post { s.applyConfig() }
        }
    }
}
