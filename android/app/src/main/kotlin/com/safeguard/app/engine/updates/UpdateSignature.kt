package com.safeguard.app.engine.updates

import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/**
 * Verifies manifest signatures against publisher keys pinned in the app.
 *
 * ECDSA P-256 / SHA-256: available on every Android version SafeGuard
 * supports (Ed25519 needs API 33). Two keys may be pinned (current and
 * next) so the signing key can rotate without breaking installed apps.
 * Private keys never exist in the app, the repository or CI.
 */
class UpdateSignatureVerifier(pinnedKeysDer: List<ByteArray>) {
    private val keys: List<PublicKey> = pinnedKeysDer.map {
        KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(it))
    }

    init {
        require(keys.isNotEmpty()) { "no pinned keys" }
    }

    fun isValid(manifest: ByteArray, signature: ByteArray): Boolean = keys.any { key ->
        try {
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(key)
                update(manifest)
                verify(signature)
            }
        } catch (e: java.security.SignatureException) {
            false // malformed signature bytes
        }
    }
}
