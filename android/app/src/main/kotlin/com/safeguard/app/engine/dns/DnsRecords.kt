package com.safeguard.app.engine.dns

import java.io.ByteArrayOutputStream

/** A resource record with names fully decompressed (labels as raw bytes). */
class DnsRecord(
    val name: List<ByteArray>,
    val type: Int,
    val rclass: Int,
    val ttl: Long,
    /** Raw rdata, except for name-bearing types where [rdataName] is set. */
    val rdata: ByteArray,
    val rdataName: List<ByteArray>? = null,
)

/**
 * Just enough RR parsing/writing to answer a SafeSearch-mapped name with
 * `name CNAME target` + the target's records, re-encoded without
 * compression so no pointer can refer into a different message.
 */
object DnsRecords {
    const val TYPE_A = 1
    const val TYPE_CNAME = 5
    const val TYPE_AAAA = 28
    private const val MAX_RECORDS = 32
    private val NAME_RDATA_TYPES = setOf(TYPE_CNAME, 2 /* NS */, 12 /* PTR */, 39 /* DNAME */)

    /** Parses the answer section of a response; null if malformed. */
    fun parseAnswers(msg: ByteArray): Pair<Int, List<DnsRecord>>? {
        if (msg.size < DnsMessage.HEADER) return null
        val rcode = Ipv4Udp.u16(msg, 2) and 0xF
        val qd = Ipv4Udp.u16(msg, 4)
        val an = Ipv4Udp.u16(msg, 6)
        if (qd > 4 || an > MAX_RECORDS) return null
        var pos = DnsMessage.HEADER
        repeat(qd) {
            pos = skipName(msg, pos) ?: return null
            pos += 4
            if (pos > msg.size) return null
        }
        val out = ArrayList<DnsRecord>(an)
        repeat(an) {
            val (name, afterName) = readName(msg, pos) ?: return null
            if (afterName + 10 > msg.size) return null
            val type = Ipv4Udp.u16(msg, afterName)
            val rclass = Ipv4Udp.u16(msg, afterName + 2)
            val ttl = ((Ipv4Udp.u16(msg, afterName + 4).toLong() shl 16) or Ipv4Udp.u16(msg, afterName + 6).toLong())
            val rdlen = Ipv4Udp.u16(msg, afterName + 8)
            val rdStart = afterName + 10
            if (rdStart + rdlen > msg.size) return null
            val rdataName = if (type in NAME_RDATA_TYPES) readName(msg, rdStart)?.first ?: return null else null
            out += DnsRecord(name, type, rclass, ttl, msg.copyOfRange(rdStart, rdStart + rdlen), rdataName)
            pos = rdStart + rdlen
        }
        return rcode to out
    }

    /**
     * Response to the app's original [query]: `original CNAME target`, then
     * every record the upstream returned for the target. The upstream RCODE
     * is kept (e.g. SERVFAIL stays SERVFAIL). Returns null if the upstream
     * answer can't be parsed, so the caller can fail safely.
     */
    fun synthesizeCname(
        query: ByteArray,
        parsed: DnsQuery,
        target: String,
        upstreamAnswer: ByteArray,
        ttl: Long = 300,
        maxSize: Int = 1472,
    ): ByteArray? {
        val (rcode, records) = parseAnswers(upstreamAnswer) ?: return null
        val body = ByteArrayOutputStream()
        body.write(query, DnsMessage.HEADER, parsed.questionEnd - DnsMessage.HEADER) // question as asked
        val answers = ArrayList<ByteArray>()
        if (rcode == 0) {
            answers += encodeRecord(
                questionLabels(query), TYPE_CNAME, 1, ttl, encodeName(labelsOf(target)),
            )
            for (r in records) {
                val rdata = r.rdataName?.let(::encodeName) ?: r.rdata
                answers += encodeRecord(r.name, r.type, r.rclass, minOf(r.ttl, ttl), rdata)
            }
        }
        val header = ByteArray(DnsMessage.HEADER)
        Ipv4Udp.put16(header, 0, parsed.id)
        Ipv4Udp.put16(header, 2, 0x8000 or (parsed.flags and 0x0100) or 0x0080 or rcode)
        Ipv4Udp.put16(header, 4, 1)
        var size = DnsMessage.HEADER + body.size()
        var included = 0
        for (a in answers) {
            if (size + a.size > maxSize) {
                header[2] = (header[2].toInt() or 0x02).toByte() // TC: client retries
                break
            }
            body.write(a)
            size += a.size
            included++
        }
        Ipv4Udp.put16(header, 6, included)
        return header + body.toByteArray()
    }

    /** "No records of this type" (NOERROR, no answers). */
    fun noData(query: ByteArray, parsed: DnsQuery): ByteArray =
        DnsMessage.errorResponse(query, parsed, 0)

    fun labelsOf(name: String): List<ByteArray> =
        name.trimEnd('.').split('.').filter { it.isNotEmpty() }.map { it.toByteArray(Charsets.US_ASCII) }

    fun encodeName(labels: List<ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        for (l in labels) {
            out.write(l.size)
            out.write(l)
        }
        out.write(0)
        return out.toByteArray()
    }

    fun nameToString(labels: List<ByteArray>): String =
        labels.joinToString(".") { String(it, Charsets.US_ASCII) }.lowercase()

    private fun encodeRecord(name: List<ByteArray>, type: Int, rclass: Int, ttl: Long, rdata: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(encodeName(name))
        val fixed = ByteArray(10)
        Ipv4Udp.put16(fixed, 0, type)
        Ipv4Udp.put16(fixed, 2, rclass)
        Ipv4Udp.put16(fixed, 4, ((ttl ushr 16) and 0xFFFF).toInt())
        Ipv4Udp.put16(fixed, 6, (ttl and 0xFFFF).toInt())
        Ipv4Udp.put16(fixed, 8, rdata.size)
        out.write(fixed)
        out.write(rdata)
        return out.toByteArray()
    }

    private fun questionLabels(query: ByteArray): List<ByteArray> =
        readName(query, DnsMessage.HEADER)?.first ?: emptyList()

    private fun skipName(msg: ByteArray, start: Int): Int? = readName(msg, start)?.second

    /** Decompressing name reader with hop limit and backwards-only pointers. */
    fun readName(msg: ByteArray, start: Int): Pair<List<ByteArray>, Int>? {
        val labels = ArrayList<ByteArray>()
        var pos = start
        var end = -1
        var hops = 0
        var total = 0
        while (true) {
            if (pos >= msg.size) return null
            val len = msg[pos].toInt() and 0xFF
            when {
                len == 0 -> {
                    if (end < 0) end = pos + 1
                    return labels to end
                }
                len and 0xC0 == 0xC0 -> {
                    if (pos + 1 >= msg.size || ++hops > 16) return null
                    if (end < 0) end = pos + 2
                    val target = ((len and 0x3F) shl 8) or (msg[pos + 1].toInt() and 0xFF)
                    if (target >= pos) return null
                    pos = target
                }
                len and 0xC0 != 0 -> return null
                else -> {
                    if (pos + 1 + len > msg.size) return null
                    total += len + 1
                    if (total > 255) return null
                    labels += msg.copyOfRange(pos + 1, pos + 1 + len)
                    pos += 1 + len
                }
            }
        }
    }
}
