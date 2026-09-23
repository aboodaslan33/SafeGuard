package com.safeguard.app.engine.ai

import com.safeguard.app.engine.rules.LruCache
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Sliding one-minute cap on inferences per content kind, so a runaway
 * caller can't keep the CPU busy. Over budget → UNAVAILABLE (never BLOCK,
 * never a silent ALLOW: the decision engine reports UNKNOWN).
 */
class InferenceBudget(
    private val perMinute: Map<ContentKind, Int> = mapOf(ContentKind.TEXT to 60, ContentKind.IMAGE to 12),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val history = HashMap<ContentKind, ArrayDeque<Long>>()

    @Synchronized
    fun tryAcquire(kind: ContentKind): Boolean {
        val limit = perMinute[kind] ?: return true
        val now = clock()
        val q = history.getOrPut(kind) { ArrayDeque() }
        while (q.isNotEmpty() && now - q.first() >= 60_000) q.removeFirst()
        if (q.size >= limit) return false
        q.addLast(now)
        return true
    }
}

/**
 * Caches *scores* (not decisions, so settings changes apply immediately)
 * and enforces the [InferenceBudget]. Keys are an HMAC of the content with
 * a per-install key, so the cache never holds the text or image itself.
 * Only OK/UNCERTAIN results are cached.
 */
class GuardedContentClassifier(
    private val delegate: ContentClassifier,
    key: ByteArray,
    private val budget: InferenceBudget = InferenceBudget(),
    capacity: Int = 256,
) : ContentClassifier {
    private val keySpec = SecretKeySpec(key.copyOf(), "HmacSHA256")
    private val cache = LruCache<String, ClassificationResult>(capacity)

    override fun isAvailable(kind: ContentKind) = delegate.isAvailable(kind)

    override fun classifyText(text: String) = classifyContent(ContentInput.Text(text))

    override fun classifyImage(bytes: ByteArray, declaredMime: String?) =
        classifyContent(ContentInput.Image(bytes, declaredMime))

    override fun classifyContent(input: ContentInput): ClassificationResult {
        val k = cacheKey(input)
        cache.get(k)?.let { return it.copy(elapsedMicros = 0) }
        if (!budget.tryAcquire(input.kind)) return ClassificationResult.unavailable(ClassificationError.RATE_LIMITED)
        val result = delegate.classifyContent(input)
        if (result.status == ClassificationStatus.OK || result.status == ClassificationStatus.UNCERTAIN) cache.put(k, result)
        return result
    }

    fun clear() = cache.clear()

    private fun cacheKey(input: ContentInput): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(keySpec)
        val bytes = when (input) {
            is ContentInput.Text -> ("t:" + input.text).toByteArray(Charsets.UTF_8)
            is ContentInput.Image -> MessageDigest.getInstance("SHA-256").digest(input.bytes).let { byteArrayOf(0x69) + it }
        }
        return mac.doFinal(bytes).joinToString("") { "%02x".format(it) }
    }
}

/** User's explicit decision about sending content off the device. */
data class CloudConsent(
    val granted: Boolean = false,
    /** Version of the disclosure the user accepted; a new version needs new consent. */
    val disclosureVersion: Int = 0,
) {
    companion object {
        const val CURRENT_DISCLOSURE = 1
        val NONE = CloudConsent()
    }
}

/**
 * Sends one input to a remote classifier. No implementation ships with
 * SafeGuard: there is no server and no endpoint. An implementation must use
 * TLS with certificate pinning, send no identifiers, and not let the server
 * retain content.
 */
interface CloudTransport {
    /** True only for an authenticated, encrypted channel. */
    val isEncrypted: Boolean
    fun classify(input: ContentInput): ClassificationResult
}

/**
 * Optional cloud classification, **off by default and unusable without
 * explicit consent** to the current disclosure and an encrypted transport.
 * `AdapterContentClassifier` additionally skips remote adapters unless the
 * user allowed them.
 */
class CloudClassifierAdapter(
    private val consent: () -> CloudConsent,
    private val transport: CloudTransport?,
) : ClassifierAdapter {
    override val id = "cloud"
    override val isRemote = true

    override fun supports(kind: ContentKind) = true

    override val isAvailable: Boolean
        get() = consented() && transport?.isEncrypted == true

    override fun classify(input: ContentInput): ClassificationResult {
        if (!consented()) return ClassificationResult.unavailable(ClassificationError.NOT_CONSENTED, id)
        val t = transport?.takeIf { it.isEncrypted } ?: return ClassificationResult.unavailable(ClassificationError.NO_MODEL, id)
        return t.classify(input)
    }

    private fun consented() = consent().let { it.granted && it.disclosureVersion >= CloudConsent.CURRENT_DISCLOSURE }
}
