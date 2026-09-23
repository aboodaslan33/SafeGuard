package com.safeguard.app.shield

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.WindowManager
import com.safeguard.app.R
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.shield.RgbaFrame
import com.safeguard.app.engine.shield.ShieldOutcome
import com.safeguard.app.protection.ProtectionManager

/**
 * Screen frames for the AI Content Shield's image model, through
 * MediaProjection only:
 *
 * - starts only after the user accepts Android's own screen-capture consent
 *   dialog; Android shows its capture indicator the whole time, and this
 *   foreground service shows a notification;
 * - frames are small (360 px wide), read in place from the ImageReader
 *   buffer, classified on the device and released at once; nothing is
 *   saved, encoded or sent;
 * - frames are only produced while a supported app the user left on is in
 *   front and protection is on; otherwise the virtual display is detached
 *   (no frames at all);
 * - stops when the user stops it (in SafeGuard or from Android), when
 *   protection or the shield stops, or when Android revokes it.
 */
class ScreenCaptureService : Service() {

    private val manager by lazy { ProtectionManager.get(this) }
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    @Volatile private var attached = false

    private val projectionCallback = object : MediaProjection.Callback() {
        // Android (or the user, from the system UI) ended the capture.
        override fun onStop() = stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (projection != null) return START_NOT_STICKY // already running
        // Android 14+: the foreground service must be running before the projection is obtained.
        startInForeground()
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        @Suppress("DEPRECATION")
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(EXTRA_DATA, Intent::class.java) else intent.getParcelableExtra(EXTRA_DATA)
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val p = try {
            if (data == null) null else mpm?.getMediaProjection(resultCode, data)
        } catch (e: SecurityException) {
            null
        }
        if (p == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val t = HandlerThread("sg-capture").also { it.start() }
        val h = Handler(t.looper)
        thread = t
        handler = h
        projection = p
        p.registerCallback(projectionCallback, h)

        val (w, hgt, dpi) = captureSize()
        val r = ImageReader.newInstance(w, hgt, PixelFormat.RGBA_8888, 2)
        r.setOnImageAvailableListener({ onImage(it) }, h)
        reader = r
        display = try {
            p.createVirtualDisplay("sg-shield", w, hgt, dpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, h)
        } catch (e: RuntimeException) {
            null
        }
        if (display == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        attached = true
        instance = this
        running = true
        manager.onScreenCaptureChanged()
        updateActive()
        return START_NOT_STICKY
    }

    private fun onImage(r: ImageReader) {
        val image = try {
            r.acquireLatestImage()
        } catch (e: IllegalStateException) {
            null
        } ?: return
        try {
            val pkg = manager.shieldForeground ?: return
            val plane = image.planes[0]
            val frame = RgbaFrame(image.width, image.height, plane.buffer, plane.rowStride, plane.pixelStride)
            val outcome = manager.shield.onFrame(pkg, frame)
            if (outcome is ShieldOutcome.Blocked) ContentShieldService.onBlocked(outcome)
        } catch (e: RuntimeException) {
            // Malformed frame or the display changed: skip it.
        } finally {
            image.close()
        }
    }

    /** Attach the display only while a supported, enabled app is in front and protection is on. */
    private fun applyActive() {
        val d = display ?: return
        val r = reader ?: return
        val active = manager.shield.isActiveFor(manager.shieldForeground, ContentKind.IMAGE)
        if (active == attached) return
        d.surface = if (active) r.surface else null
        attached = active
    }

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        val en = manager.config.uiLanguage == "en"
        if (Build.VERSION.SDK_INT >= 26) {
            nm?.createNotificationChannel(
                NotificationChannel(CHANNEL, if (en) "Image checks" else "فحص الصور", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = builder
            .setSmallIcon(R.drawable.ic_shield_mark)
            .setContentTitle(if (en) "SafeGuard is checking images" else "SafeGuard يفحص الصور")
            .setContentText(
                if (en) "On-device checks in supported apps. Nothing is saved or sent."
                else "فحص على الجهاز في التطبيقات المدعومة. لا يُحفظ ولا يُرسل أي شيء.",
            )
            .setContentIntent(manager.launchIntent())
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    /** Frames 360 px wide (aspect kept): plenty for a 224 px model, cheap to read. */
    private fun captureSize(): Triple<Int, Int, Int> {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        getSystemService(WindowManager::class.java)?.defaultDisplay?.getRealMetrics(metrics)
        val sw = metrics.widthPixels.takeIf { it > 0 } ?: 1080
        val sh = metrics.heightPixels.takeIf { it > 0 } ?: 2400
        val w = CAPTURE_WIDTH.coerceAtMost(sw)
        val h = (sh.toLong() * w / sw).toInt().coerceIn(1, RgbaFrame.MAX_SIDE)
        return Triple(w, h, (metrics.densityDpi.takeIf { it > 0 } ?: 320) * w / sw)
    }

    override fun onDestroy() {
        running = false
        instance = null
        val t = thread
        val h = handler
        if (t != null && h != null) {
            // Release on the capture thread, after any frame being processed.
            h.post { release() }
            t.quitSafely()
        } else {
            release()
        }
        thread = null
        handler = null
        manager.onScreenCaptureChanged()
        super.onDestroy()
    }

    private fun release() {
        attached = false
        try {
            display?.release()
        } catch (_: RuntimeException) {
        }
        display = null
        reader?.close()
        reader = null
        projection?.let {
            it.unregisterCallback(projectionCallback)
            it.stop()
        }
        projection = null
    }

    companion object {
        private const val EXTRA_RESULT_CODE = "result_code"
        private const val EXTRA_DATA = "data"
        private const val CHANNEL = "screen_shield"
        private const val NOTIFICATION_ID = 0x5648
        private const val CAPTURE_WIDTH = 360

        @Volatile private var instance: ScreenCaptureService? = null

        /** True while frames can be captured (consent given this session, service alive). */
        @Volatile var running = false
            private set

        /** The consent intent for Android's screen-capture dialog (whole screen on Android 14+). */
        fun consentIntent(context: Context): Intent? {
            val mpm = context.getSystemService(MediaProjectionManager::class.java) ?: return null
            return if (Build.VERSION.SDK_INT >= 34) {
                mpm.createScreenCaptureIntent(android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay())
            } else {
                mpm.createScreenCaptureIntent()
            }
        }

        /** Starts capture with the result of the consent dialog (called from the activity). */
        fun start(context: Context, resultCode: Int, data: Intent) {
            val i = Intent(context, ScreenCaptureService::class.java)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_DATA, data)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
        }

        /** Ends the capture (and the projection): new consent is needed to start again. */
        fun stop() {
            instance?.stopSelf()
        }

        /** Foreground app or protection state changed: attach or detach the display. */
        fun updateActive() {
            val s = instance ?: return
            s.handler?.post { s.applyActive() }
        }
    }
}
