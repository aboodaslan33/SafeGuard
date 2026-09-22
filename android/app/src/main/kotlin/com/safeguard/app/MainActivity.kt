package com.safeguard.app

import android.content.Intent
import android.view.WindowManager
import com.safeguard.app.channel.ProtectionChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Host activity. Each native concern has its own channel:
 *  - `com.safeguard.app/device`: window security (FLAG_SECURE on PIN screens)
 *  - `com.safeguard.app/protection` (+ `/status` events): VPN / DNS filter,
 *    see [ProtectionChannel].
 */
class MainActivity : FlutterActivity() {

    private var protectionChannel: ProtectionChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, DEVICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecureScreen" -> {
                    setSecureScreen(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        protectionChannel = ProtectionChannel(messenger, this)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        protectionChannel?.dispose()
        protectionChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Deprecated("Needed for VpnService.prepare(), which only offers an Intent.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (protectionChannel?.onActivityResult(requestCode, resultCode) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
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
