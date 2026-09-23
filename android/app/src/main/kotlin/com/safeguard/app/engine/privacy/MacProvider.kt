package com.safeguard.app.engine.privacy

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Source of initialised HMAC-SHA256 instances. On a device the key lives in
 * the Android Keystore and is never exported (see KeystoreHmacKey); the
 * engine only ever sees a ready [Mac], never key bytes.
 */
fun interface MacProvider {
    fun newMac(): Mac

    companion object {
        /** Raw-key provider for JVM tests and as an in-memory fallback. */
        fun fromBytes(key: ByteArray): MacProvider {
            require(key.size >= 16) { "key too short" }
            val spec = SecretKeySpec(key.copyOf(), "HmacSHA256")
            return MacProvider { Mac.getInstance("HmacSHA256").apply { init(spec) } }
        }
    }
}
