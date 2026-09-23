package com.safeguard.app.engine.privacy

/**
 * Short, non-reversible identifier for a query, for correlating repeated
 * events without storing text.
 *
 * HMAC-SHA256 with a per-install random key (a non-exportable Android Keystore key),
 * truncated to 32 bits. The key prevents precomputed dictionaries of common
 * queries; truncation means many different queries share an id, so the id
 * can't be used to prove what was typed.
 */
class QueryHasher(private val macs: MacProvider) {
    constructor(key: ByteArray) : this(MacProvider.fromBytes(key))

    fun shortHash(normalizedText: String): String {
        val digest = macs.newMac().doFinal(normalizedText.toByteArray(Charsets.UTF_8))
        return digest.take(4).joinToString("") { "%02x".format(it) }
    }
}
