package com.safeguard.app.engine.domain

import java.net.IDN
import java.util.Locale

/**
 * Domain parsing and validation.
 *
 * Matching is label-based, never substring-based: a rule for `example.com`
 * matches `example.com`, `www.example.com` and `a.b.example.com`, but never
 * `safe-example.com` or `example.com.evil.net`.
 */
object DomainName {
    const val MAX_LENGTH = 253
    private const val MAX_LABEL = 63

    /**
     * Normalises a name taken from a DNS query: lower-case ASCII, no trailing
     * dot. Underscores are accepted because they appear in real service
     * names (`_dmarc.example.com`). Returns null for anything malformed.
     */
    fun normalizeQueryName(raw: String): String? {
        val name = raw.trim().lowercase(Locale.ROOT).removeSuffix(".")
        if (name.isEmpty() || name.length > MAX_LENGTH) return null
        val labels = name.split('.')
        if (labels.any { !isValidLabel(it, allowUnderscore = true) }) return null
        return name
    }

    /**
     * Parses user input for a rule (blocklist / allowlist). Accepts a bare
     * domain or a pasted URL, converts internationalised names to punycode,
     * strips a leading `www.`, and requires at least two labels. IP
     * addresses are rejected: DNS filtering can't act on them.
     */
    fun parseRuleDomain(input: String): String? {
        var s = input.trim()
        if (s.isEmpty() || s.length > 2048) return null
        s = s.substringAfter("://", s)
        s = s.substringBefore('/').substringBefore('?').substringBefore('#')
        s = s.substringAfterLast('@')
        if (s.startsWith("[")) return null // IPv6 literal
        s = s.substringBefore(':')
        s = s.removeSuffix(".")
        val ascii = try {
            IDN.toASCII(s, IDN.USE_STD3_ASCII_RULES)
        } catch (e: IllegalArgumentException) {
            return null
        }.lowercase(Locale.ROOT)
        val name = ascii.removePrefix("www.")
        if (name.isEmpty() || name.length > MAX_LENGTH) return null
        val labels = name.split('.')
        if (labels.size < 2) return null
        if (labels.any { !isValidLabel(it, allowUnderscore = false) }) return null
        if (isIpv4Literal(name)) return null
        // A top-level domain must not be purely numeric.
        if (labels.last().all { it.isDigit() }) return null
        return name
    }

    /**
     * All suffixes of [name] with at least two labels, most specific first.
     * `a.b.example.com` → [a.b.example.com, b.example.com, example.com].
     * A single-label name yields itself only.
     */
    fun matchCandidates(name: String): List<String> {
        val labels = name.split('.')
        if (labels.size < 2) return listOf(name)
        val out = ArrayList<String>(labels.size - 1)
        for (i in 0 until labels.size - 1) {
            out.add(labels.subList(i, labels.size).joinToString("."))
        }
        return out
    }

    /** True if [name] is [ruleDomain] or a subdomain of it. */
    fun isSameOrSubdomain(name: String, ruleDomain: String): Boolean =
        name == ruleDomain || name.endsWith(".$ruleDomain")

    private fun isValidLabel(label: String, allowUnderscore: Boolean): Boolean {
        if (label.isEmpty() || label.length > MAX_LABEL) return false
        if (label.first() == '-' || label.last() == '-') return false
        for (c in label) {
            val ok = c in 'a'..'z' || c in '0'..'9' || c == '-' ||
                (allowUnderscore && c == '_')
            if (!ok) return false
        }
        return true
    }

    private fun isIpv4Literal(name: String): Boolean {
        val parts = name.split('.')
        return parts.size == 4 && parts.all { p ->
            p.isNotEmpty() && p.length <= 3 && p.all { it.isDigit() } && p.toInt() <= 255
        }
    }
}
