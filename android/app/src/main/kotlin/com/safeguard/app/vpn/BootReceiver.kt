package com.safeguard.app.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import com.safeguard.app.engine.health.IncidentKind
import com.safeguard.app.protection.ProtectionManager

/**
 * Best-effort restart after reboot or app update.
 *
 * Works only if the user previously granted VPN consent and left protection
 * on. Android may still refuse a background start on some devices/OEMs;
 * the reliable mechanism is the system "Always-on VPN" setting, which
 * starts the service itself (SafeGuard handles that start path too).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val manager = ProtectionManager.get(context)
        // Check settings → check consent → start; record what happened so the
        // app shows the real state instead of assuming protection resumed.
        val now = System.currentTimeMillis()
        when {
            !manager.config.enabled -> manager.config.recordBoot(BOOT_DISABLED, now)
            manager.config.safeMode -> manager.config.recordBoot(BOOT_SAFE_MODE, now)
            VpnService.prepare(context) != null -> {
                manager.config.recordBoot(BOOT_PERMISSION_REQUIRED, now)
                manager.status.permissionRequired()
                manager.recordIncident(IncidentKind.BOOT_START_FAILED)
            }
            else -> try {
                SafeGuardVpnService.start(context)
                manager.config.recordBoot(BOOT_START_REQUESTED, now)
            } catch (e: IllegalStateException) {
                // Background start not allowed on this device right now.
                Log.w("SafeGuard", "could not start VPN after boot", e)
                manager.config.recordBoot(BOOT_BLOCKED, now)
                manager.status.failed("boot start blocked by the system")
                manager.recordIncident(IncidentKind.BOOT_START_FAILED)
            }
        }
    }

    companion object {
        const val BOOT_DISABLED = "disabled"
        const val BOOT_SAFE_MODE = "safe_mode"
        const val BOOT_PERMISSION_REQUIRED = "permission_required"
        const val BOOT_START_REQUESTED = "start_requested"
        const val BOOT_BLOCKED = "blocked"
    }
}
