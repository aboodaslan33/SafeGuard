package com.safeguard.app.protection

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.safeguard.app.R
import com.safeguard.app.engine.health.OverallHealth

/**
 * The one notification SafeGuard posts: "protection is degraded/stopped".
 * Posted only if the user kept alerts on and Android allows notifications
 * (POST_NOTIFICATIONS on 13+). Contains no domains, apps or queries.
 */
class ProtectionAlerts(
    context: Context,
    private val config: ProtectionConfigStore,
    private val launch: () -> PendingIntent,
) {
    private val context = context.applicationContext
    private val nm = this.context.getSystemService(NotificationManager::class.java)

    fun permissionGranted(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun canNotify(): Boolean =
        config.alertsEnabled && permissionGranted() && (nm?.areNotificationsEnabled() == true)

    fun showDegraded(overall: OverallHealth, reason: String) {
        if (!canNotify()) return
        val en = config.uiLanguage == "en"
        fun tr(ar: String, english: String) = if (en) english else ar
        val stopped = overall == OverallHealth.NOT_PROTECTED
        val title = if (stopped) {
            tr("حماية SafeGuard متوقفة", "SafeGuard protection stopped")
        } else {
            tr("حماية SafeGuard جزئية", "SafeGuard protection is partial")
        }
        val text = when {
            reason.contains("revoked") || reason.contains("other_vpn") -> tr(
                "فُصل اتصال VPN (ربما بسبب تطبيق VPN آخر). افتح SafeGuard لإعادة التفعيل.",
                "The VPN was disconnected (maybe by another VPN app). Open SafeGuard to turn it back on.",
            )
            reason.contains("private_dns") -> tr(
                "«DNS الخاص» في Android يتجاوز الفلترة. افتح SafeGuard لمعرفة الحل.",
                "Android's Private DNS bypasses filtering. Open SafeGuard to fix it.",
            )
            stopped -> tr(
                "لا تتم فلترة الشبكة الآن. افتح SafeGuard لمعرفة السبب.",
                "Network filtering isn't running now. Open SafeGuard to see why.",
            )
            else -> tr(
                "إحدى طبقات الحماية لا تعمل كما يجب. افتح SafeGuard للتفاصيل.",
                "One protection layer isn't working as it should. Open SafeGuard for details.",
            )
        }
        ensureChannel(tr("حالة الحماية", "Protection status"))
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else legacyBuilder()
        val n = builder
            .setSmallIcon(R.drawable.ic_shield_mark)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(launch())
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .build()
        try {
            nm?.notify(ID, n)
        } catch (e: SecurityException) {
            // Permission revoked between the check and the call.
        }
    }

    fun clear() {
        nm?.cancel(ID)
    }

    @Suppress("DEPRECATION")
    private fun legacyBuilder() = Notification.Builder(context)

    private fun ensureChannel(name: String) {
        if (Build.VERSION.SDK_INT < 26) return
        nm?.createNotificationChannel(NotificationChannel(CHANNEL, name, NotificationManager.IMPORTANCE_DEFAULT))
    }

    private companion object {
        const val CHANNEL = "protection_status"
        const val ID = 0x5647
    }
}
