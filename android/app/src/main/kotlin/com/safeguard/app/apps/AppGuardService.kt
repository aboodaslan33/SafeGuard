package com.safeguard.app.apps

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import com.safeguard.app.engine.apps.AppAction
import com.safeguard.app.protection.ProtectionManager

/**
 * App Protection, and nothing else.
 *
 * Configured (res/xml/accessibility_service_config.xml) to receive only
 * TYPE_WINDOW_STATE_CHANGED events with canRetrieveWindowContent=false:
 * SafeGuard learns *which app* came to the foreground, never what is on
 * screen, typed, or read. No overlay is drawn.
 *
 * When a protected app opens, SafeGuard does what Android supports: it
 * sends the user to the home screen and shows its own "app protected"
 * activity. It cannot filter content inside apps.
 *
 * The user enables this service themselves in Android's accessibility
 * settings, after SafeGuard's in-app disclosure, and can disable it there
 * at any time.
 */
class AppGuardService : AccessibilityService() {

    private val manager by lazy { ProtectionManager.get(this) }
    private var lastBlocked: String? = null
    private var lastBlockedAt = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == packageName) return

        val decision = manager.onForegroundApp(pkg)
        if (decision.action != AppAction.BLOCK_APP) return

        // One app launch emits several window events; act once per launch.
        val now = System.currentTimeMillis()
        if (pkg == lastBlocked && now - lastBlockedAt < REPEAT_WINDOW_MS) return
        lastBlocked = pkg
        lastBlockedAt = now

        performGlobalAction(GLOBAL_ACTION_HOME)
        startActivity(
            Intent(this, AppBlockedActivity::class.java)
                .putExtra(AppBlockedActivity.EXTRA_LABEL, manager.appLabel(pkg))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY),
        )
    }

    override fun onInterrupt() = Unit

    private companion object {
        const val REPEAT_WINDOW_MS = 1500L
    }
}
