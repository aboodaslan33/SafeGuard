package com.safeguard.app

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Host activity. Native capabilities are exposed to Flutter through one
 * method channel per concern; Phase 1 only needs window security.
 *
 * Phase 2 adds a separate channel for the VpnService-based DNS filter so
 * that UI code and enforcement code stay decoupled.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecureScreen" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setSecureScreen(enabled)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * FLAG_SECURE hides the window from screenshots, screen recording,
     * casting and the recent-apps thumbnail while a PIN is on screen.
     */
    private fun setSecureScreen(enabled: Boolean) {
        runOnUiThread {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }

    private companion object {
        const val DEVICE_CHANNEL = "com.safeguard.app/device"
    }
}
