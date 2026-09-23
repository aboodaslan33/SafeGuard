package com.safeguard.app.shield

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.safeguard.app.apps.AppBlockedActivity
import com.safeguard.app.engine.shield.BlockAction
import com.safeguard.app.engine.shield.BlockEscalation
import com.safeguard.app.engine.shield.NodeView
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
 * - Editable and password fields are never read; codes, numbers, e-mails
 *   and links are dropped ([VisibleTextExtractor]).
 * - Text is classified in memory on a background thread and discarded; it
 *   is never logged, stored or sent. Only block metadata is logged.
 * - No overlay is drawn. A block first swipes to the next item (reels,
 *   shorts, feeds); if blocked content is still there it goes Back, then
 *   Home with SafeGuard's own blocking screen ([BlockEscalation]). The
 *   only gestures performed are that one swipe, Back and Home.
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

    private val snapshot = Runnable { takeSnapshot() }

    override fun onServiceConnected() {
        instance = WeakReference(this)
        applyConfig()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return
        if (SupportedApps.forPackage(pkg) == null) return
        val engine = manager.shield
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                if (pkg != foreground) {
                    foreground = pkg
                    manager.shieldForeground = pkg
                    engine.onForeground(pkg)
                    ScreenCaptureService.updateActive()
                }
            }
            else -> engine.onContentChanged()
        }
        if (!engine.isActiveFor(pkg)) {
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
        if (busy.get()) return reschedule()
        if (!engine.wantsText(pkg)) return reschedule()
        val root = rootInActiveWindow ?: return
        val text = try {
            if (root.packageName?.toString() != pkg) return
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

    /** Gets blocked content off the screen: skip, then Back, then Home + blocking screen. */
    private fun act(outcome: ShieldOutcome.Blocked) {
        val e = outcome.event
        if (destroyed || e.packageName != foreground) return
        val action = escalation.next(e.packageName, e.timestamp)
        if (!manager.onShieldBlock(e, action)) return
        manager.shield.onContentChanged() // the screen is about to change: let it settle
        when (action) {
            BlockAction.SKIP -> if (!swipeToNext()) performGlobalAction(GLOBAL_ACTION_BACK)
            BlockAction.BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            BlockAction.HOME -> {
                performGlobalAction(GLOBAL_ACTION_HOME)
                startActivity(
                    Intent(this, AppBlockedActivity::class.java)
                        .putExtra(AppBlockedActivity.EXTRA_KIND, AppBlockedActivity.KIND_CONTENT)
                        .putExtra(AppBlockedActivity.EXTRA_CATEGORY, e.category.id)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY),
                )
            }
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
        info.packageNames = (packages.ifEmpty { SupportedApps.allPackages }).toTypedArray()
        info.eventTypes = when {
            packages.isEmpty() -> 0 // shield off: no events at all
            active -> AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_SCROLLED
            // Protection off or paused: app switches only (no content), to notice when it resumes.
            else -> AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        }
        info.flags = AccessibilityServiceInfo.DEFAULT
        serviceInfo = info
        if (!active) {
            main.removeCallbacks(snapshot)
            foreground = null
            manager.shieldForeground = null
            manager.shield.onForeground(null)
            escalation.reset()
        }
        ScreenCaptureService.updateActive()
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        destroyed = true
        main.removeCallbacks(snapshot)
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

        @Volatile private var instance: WeakReference<ContentShieldService>? = null

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
