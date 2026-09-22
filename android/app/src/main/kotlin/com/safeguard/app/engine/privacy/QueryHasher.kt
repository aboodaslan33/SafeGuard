package com.safeguard.app.engine.privacy

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Short, non-reversible identifier for a query, for correlating repeated
 * events without storing text.
 *
 * HMAC-SHA256 with a per-install random key (kept in app-private storage),
 * truncated to 32 bits. The key prevents precomputed dictionaries of common
 * queries; truncation means many different queries share an id, so the id
 * can't be used to prove what was typed.
 */
class QueryHasher(key: ByteArray) {
    init {
        require(key.size >= 16) { "key too short" }
    }

    private val keySpec = SecretKeySpec(key.copyOf(), "HmacSHA256")

    fun shortHash(normalizedText: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(keySpec)
        val digest = mac.doFinal(normalizedText.toByteArray(Charsets.UTF_8))
        return digest.take(4).joinToString("") { "%02x".format(it) }
    }
}
