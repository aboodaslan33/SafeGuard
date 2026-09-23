package com.safeguard.app.engine.rules

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong

/**
 * Large category blocklists in a compact, read-only form.
 *
 * A list is a sorted array of 64-bit FNV-1a hashes of exact hostnames
 * (lowercase ASCII, no trailing dot). A name is looked up by hashing each
 * of its suffix candidates (`a.b.example.com`, `b.example.com`,
 * `example.com`), so an entry also covers its own subdomains — never its
 * parent or siblings (`blog.tumblr.com` does not block `tumblr.com`).
 *
 * File format (big-endian), validated strictly by [HashedDomainList.parse]:
 * ```
 * "SGBL" | u16 version=1 | u8 len, ASCII category id | u32 count | u64 hash[count] (ascending, unique)
 * ```
 * The asset can be memory-mapped, so ~1.3 M domains cost ~10 MB of file and
 * almost no heap. A hash collision can only cause a false block with
 * probability ≈ count / 2^64 per lookup (≈ 10⁻¹³ for the bundled lists).
 */
class HashedDomainList private constructor(
    val category: Category,
    private val buf: ByteBuffer,
    private val offset: Int,
    val size: Int,
) {
    fun contains(domain: String): Boolean {
        val h = hash(domain)
        var lo = 0
        var hi = size - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val v = buf.getLong(offset + mid * 8)
            val c = java.lang.Long.compareUnsigned(v, h)
            when {
                c < 0 -> lo = mid + 1
                c > 0 -> hi = mid - 1
                else -> return true
            }
        }
        return false
    }

    companion object {
        private val MAGIC = "SGBL".toByteArray(Charsets.US_ASCII)
        const val VERSION = 1

        /** FNV-1a 64 over the ASCII bytes of a normalised hostname. */
        fun hash(domain: String): Long {
            var h = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
            for (ch in domain) {
                h = h xor (ch.code.toLong() and 0xFF)
                h *= 0x100000001b3L
            }
            return h
        }

        /** Validates header, size and ordering (a full O(n) pass, done once). */
        fun parse(raw: ByteBuffer): HashedDomainList {
            val b = raw.duplicate().order(ByteOrder.BIG_ENDIAN)
            b.position(0)
            fun need(n: Int) = require(b.remaining() >= n) { "truncated list" }
            need(7)
            val magic = ByteArray(4).also { b.get(it) }
            require(magic.contentEquals(MAGIC)) { "bad magic" }
            require(b.short.toInt() == VERSION) { "unsupported version" }
            val len = b.get().toInt() and 0xFF
            need(len + 4)
            val id = ByteArray(len).also { b.get(it) }.toString(Charsets.US_ASCII)
            val category = Category.fromId(id)
            require(category != null && category.isFilterable) { "bad category" }
            val count = b.int
            require(count >= 0 && b.remaining().toLong() == count * 8L) { "size mismatch" }
            val offset = b.position()
            var prev = 0L
            for (i in 0 until count) {
                val v = b.getLong(offset + i * 8)
                require(i == 0 || java.lang.Long.compareUnsigned(prev, v) < 0) { "not sorted/unique" }
                prev = v
            }
            return HashedDomainList(category, b, offset, count)
        }

        /** Build-time helper (tests/tools): serialises [domains] for [category]. */
        fun build(category: Category, domains: Collection<String>): ByteArray {
            val hashes = domains.map(::hash).distinct().sortedWith { a, c -> java.lang.Long.compareUnsigned(a, c) }
            val id = category.id.toByteArray(Charsets.US_ASCII)
            val out = ByteBuffer.allocate(4 + 2 + 1 + id.size + 4 + hashes.size * 8).order(ByteOrder.BIG_ENDIAN)
            out.put(MAGIC).putShort(VERSION.toShort()).put(id.size.toByte()).put(id).putInt(hashes.size)
            hashes.forEach { out.putLong(it) }
            return out.array()
        }
    }
}

/**
 * Domains no bundled list may ever block by exact match: core platforms and
 * shared hosting roots, so a bad list entry can't take down the whole of
 * Google, Instagram, WhatsApp… (their individual subdomains in a list are
 * still honoured, e.g. one adult blog on a blog host).
 */
object NeverBlock {
    val domains: Set<String> = setOf(
        "google.com", "youtube.com", "gstatic.com", "googleapis.com", "googleusercontent.com", "googlevideo.com",
        "instagram.com", "cdninstagram.com", "facebook.com", "fbcdn.net", "whatsapp.com", "whatsapp.net",
        "apple.com", "icloud.com", "microsoft.com", "live.com", "office.com", "windows.com",
        "twitter.com", "x.com", "twimg.com", "tiktok.com", "snapchat.com", "telegram.org", "t.me",
        "reddit.com", "wikipedia.org", "wikimedia.org", "github.com", "github.io",
        "amazonaws.com", "cloudfront.net", "akamaihd.net", "akamaized.net", "cloudflare.com",
        "blogspot.com", "tumblr.com", "wordpress.com", "pages.dev", "vercel.app", "netlify.app",
        "web.app", "firebaseapp.com", "appspot.com", "herokuapp.com", "azurewebsites.net",
    )

    fun allows(domain: String) = domain !in domains
}

/**
 * Serves the bundled lists through the [RuleStore] interface, so the rule
 * engine applies them with the usual precedence (user allowlist and
 * blocklist first; a list rule blocks only if its category is enabled) and
 * its LRU cache. Read-only.
 */
class BundledListStore(private val lists: () -> List<HashedDomainList>) {
    fun find(domains: Collection<String>): List<Rule> {
        val all = lists()
        if (all.isEmpty()) return emptyList()
        val out = ArrayList<Rule>(0)
        for (d in domains) {
            if (!NeverBlock.allows(d)) continue
            for (l in all) {
                if (l.contains(d)) out += Rule(d, l.category, RuleAction.BLOCK, source = RuleSource.BUNDLED_LIST, version = 1)
            }
        }
        return out
    }

    fun totalEntries(): Int = lists().sumOf { it.size }
}

/** [primary] (SQLite) plus the read-only bundled lists for lookups. */
class CompositeRuleStore(
    private val primary: RuleStore,
    private val bundled: BundledListStore,
    private val onPrimaryFailure: (RuntimeException) -> Unit = {},
) : RuleStore by primary {
    private val failures = AtomicLong()

    /** Lookups where the primary (SQLite) store failed; results then aren't cached. */
    val primaryFailures: Long get() = failures.get()

    /**
     * A database error must not take the DNS path down: the bundled lists
     * keep blocking. User rules (including the allowlist) are unavailable
     * until the database recovers, so this fails closed, not open.
     */
    override fun findEnabled(domains: Collection<String>): List<Rule> {
        val user = try {
            primary.findEnabled(domains)
        } catch (e: RuntimeException) {
            failures.incrementAndGet()
            onPrimaryFailure(e)
            emptyList()
        }
        return user + bundled.find(domains)
    }
}
