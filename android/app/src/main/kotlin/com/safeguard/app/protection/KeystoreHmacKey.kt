package com.safeguard.app.protection

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import com.safeguard.app.engine.privacy.MacProvider
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

/**
 * Per-install HMAC-SHA256 key for event ids and the AI score cache, held in
 * the Android Keystore: generated on the device, non-exportable, never in
 * SharedPreferences, backups or logs.
 *
 * If the Keystore is unusable on a device (rare OEM bugs), an in-memory
 * random key is used for this process only — ids then stop correlating
 * across restarts, which loses nothing sensitive.
 */
class KeystoreHmacKey(context: Context) : MacProvider {
    private val legacyPrefs = context.applicationContext.getSharedPreferences("safeguard_protection", Context.MODE_PRIVATE)

    @Volatile private var key: SecretKey? = null
    @Volatile private var fallback: MacProvider? = null

    init {
        // Phase ≤5 kept a raw key in SharedPreferences; remove it.
        if (legacyPrefs.contains(LEGACY_PREF)) legacyPrefs.edit().remove(LEGACY_PREF).apply()
    }

    override fun newMac(): Mac {
        fallback?.let { return it.newMac() }
        return try {
            Mac.getInstance(ALGORITHM).apply { init(key()) }
        } catch (e: Exception) {
            Log.w(TAG, "keystore HMAC key unavailable; using a process-only key")
            val f = MacProvider.fromBytes(ByteArray(32).also { SecureRandom().nextBytes(it) })
            fallback = f
            f.newMac()
        }
    }

    /** Deletes the key; the next use generates a fresh one ("delete local data"). */
    @Synchronized
    fun rotate() {
        key = null
        fallback = null
        try {
            KeyStore.getInstance(PROVIDER).apply { load(null) }.deleteEntry(ALIAS)
        } catch (e: Exception) {
            Log.w(TAG, "could not delete keystore HMAC key")
        }
    }

    @Synchronized
    private fun key(): SecretKey {
        key?.let { return it }
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        val existing = store.getKey(ALIAS, null) as? SecretKey
        val k = existing ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, PROVIDER).run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN).build())
            generateKey()
        }
        key = k
        return k
    }

    private companion object {
        const val TAG = "SafeGuard"
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "safeguard.event_hmac.v1"
        const val ALGORITHM = "HmacSHA256"
        const val LEGACY_PREF = "event_hash_key"
    }
}
