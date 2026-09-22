package com.safeguard.app.engine.dns

import java.util.Locale

/** The parts of a DNS query SafeGuard needs to make a decision. */
class DnsQuery(
    val id: Int,
    val flags: Int,
    /** Lower-case name without trailing dot; may still be malformed. */
    val name: String,
    val type: Int,
    val qclass: Int,
    /** Offset just past the question section in the original message. */
    val questionEnd: Int,
)

/**
 * DNS wire-format helpers (RFC 1035). Parsing is defensive: every read is
 * bounds-checked, compression pointers are followed with a hop limit, and
 * anything unexpected yields null instead of an exception.
 */
object DnsMessage {
    const val HEADER = 12
    const val RCODE_SERVFAIL = 2
    const val RCODE_NXDOMAIN = 3
    private const val MAX_NAME = 255
    private const val MAX_POINTER_HOPS = 16

    /** Parses a standard query with exactly one question, or returns null. */
    fun parseQuery(msg: ByteArray): DnsQuery? {
        if (msg.size < HEADER + 5) return null
        val flags = Ipv4Udp.u16(msg, 2)
        val isResponse = flags and 0x8000 != 0
        val opcode = (flags ushr 11) and 0xF
        if (isResponse || opcode != 0) return null
        if (Ipv4Udp.u16(msg, 4) != 1) return null // QDCOUNT

        val (name, afterName) = readName(msg, HEADER) ?: return null
        if (afterName + 4 > msg.size) return null
        return DnsQuery(
            id = Ipv4Udp.u16(msg, 0),
            flags = flags,
            name = name,
            type = Ipv4Udp.u16(msg, afterName),
            qclass = Ipv4Udp.u16(msg, afterName + 2),
            questionEnd = afterName + 4,
        )
    }

    /** Query ID of any DNS message, or -1 if too short. */
    fun id(msg: ByteArray): Int = if (msg.size >= 2) Ipv4Udp.u16(msg, 0) else -1

    /**
     * A reply that carries only the question and the given RCODE. Used for
     * blocking (NXDOMAIN: "this name does not exist" — every resolver and
     * browser handles it, nothing gets connected) and for upstream failure
     * (SERVFAIL, so clients fail fast instead of timing out).
     */
    fun errorResponse(query: ByteArray, parsed: DnsQuery, rcode: Int): ByteArray {
        val out = ByteArray(parsed.questionEnd)
        query.copyInto(out, 0, 0, parsed.questionEnd)
        val rd = parsed.flags and 0x0100
        val flags = 0x8000 or rd or 0x0080 or (rcode and 0xF) // QR, RD (copied), RA
        Ipv4Udp.put16(out, 2, flags)
        Ipv4Udp.put16(out, 4, 1) // QDCOUNT
        Ipv4Udp.put16(out, 6, 0) // ANCOUNT
        Ipv4Udp.put16(out, 8, 0) // NSCOUNT
        Ipv4Udp.put16(out, 10, 0) // ARCOUNT (EDNS OPT dropped)
        return out
    }

    /** Builds a query message (used by tests and diagnostics). */
    fun buildQuery(id: Int, name: String, type: Int = 1): ByteArray {
        val labels = name.trimEnd('.').split('.')
        val size = HEADER + labels.sumOf { it.length + 1 } + 1 + 4
        val out = ByteArray(size)
        Ipv4Udp.put16(out, 0, id)
        Ipv4Udp.put16(out, 2, 0x0100) // RD
        Ipv4Udp.put16(out, 4, 1)
        var i = HEADER
        for (label in labels) {
            val bytes = label.toByteArray(Charsets.US_ASCII)
            out[i++] = bytes.size.toByte()
            bytes.copyInto(out, i)
            i += bytes.size
        }
        out[i++] = 0
        Ipv4Udp.put16(out, i, type)
        Ipv4Udp.put16(out, i + 2, 1)
        return out
    }

    /** Returns (name, offset after the name at [start]) or null. */
    private fun readName(msg: ByteArray, start: Int): Pair<String, Int>? {
        val sb = StringBuilder()
        var pos = start
        var end = -1
        var hops = 0
        while (true) {
            if (pos >= msg.size) return null
            val len = msg[pos].toInt() and 0xFF
            when {
                len == 0 -> {
                    if (end < 0) end = pos + 1
                    break
                }
                len and 0xC0 == 0xC0 -> {
                    if (pos + 1 >= msg.size || ++hops > MAX_POINTER_HOPS) return null
                    if (end < 0) end = pos + 2
                    val target = ((len and 0x3F) shl 8) or (msg[pos + 1].toInt() and 0xFF)
                    if (target >= pos) return null // pointers must go backwards
                    pos = target
                }
                len and 0xC0 != 0 -> return null // reserved label types
                else -> {
                    if (pos + 1 + len > msg.size) return null
                    if (sb.isNotEmpty()) sb.append('.')
                    for (k in 1..len) {
                        val c = msg[pos + k].toInt() and 0xFF
                        // Non-printable bytes can't match any rule; keep a
                        // placeholder so the name fails validation later.
                        sb.append(if (c in 0x21..0x7E) c.toChar() else '\u0000')
                    }
                    if (sb.length > MAX_NAME) return null
                    pos += 1 + len
                }
            }
        }
        return sb.toString().lowercase(Locale.ROOT) to end
    }
}
