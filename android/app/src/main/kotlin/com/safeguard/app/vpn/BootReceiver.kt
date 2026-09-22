package com.safeguard.app.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
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
        if (!manager.config.enabled) return
        if (VpnService.prepare(context) != null) {
            manager.status.permissionRequired()
            return
        }
        try {
            SafeGuardVpnService.start(context)
        } catch (e: IllegalStateException) {
            // Background start not allowed on this device right now.
            Log.w("SafeGuard", "could not start VPN after boot", e)
            manager.status.failed("boot start blocked by the system")
        }
    }
}
