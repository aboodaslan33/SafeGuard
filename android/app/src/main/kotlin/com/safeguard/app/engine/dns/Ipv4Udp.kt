package com.safeguard.app.engine.dns

/**
 * Minimal IPv4 + UDP codec for packets read from / written to the tun
 * interface. Only what DNS needs; everything else is rejected.
 */
class UdpDatagram(
    val sourceAddress: ByteArray,
    val destinationAddress: ByteArray,
    val sourcePort: Int,
    val destinationPort: Int,
    val payload: ByteArray,
)

object Ipv4Udp {
    private const val PROTOCOL_UDP = 17
    private const val UDP_HEADER = 8

    /** Returns null for anything that isn't a complete, unfragmented IPv4/UDP packet. */
    fun parse(buf: ByteArray, length: Int): UdpDatagram? {
        if (length < 20 + UDP_HEADER || length > buf.size) return null
        val version = (buf[0].toInt() ushr 4) and 0xF
        if (version != 4) return null
        val ihl = (buf[0].toInt() and 0xF) * 4
        if (ihl < 20 || ihl + UDP_HEADER > length) return null
        val totalLength = u16(buf, 2)
        if (totalLength < ihl + UDP_HEADER || totalLength > length) return null
        val flagsFragment = u16(buf, 6)
        val moreFragments = flagsFragment and 0x2000 != 0
        val fragmentOffset = flagsFragment and 0x1FFF
        if (moreFragments || fragmentOffset != 0) return null
        if (buf[9].toInt() and 0xFF != PROTOCOL_UDP) return null

        val udpLength = u16(buf, ihl + 4)
        if (udpLength < UDP_HEADER || ihl + udpLength > totalLength) return null
        val payloadLength = udpLength - UDP_HEADER
        val payloadStart = ihl + UDP_HEADER
        return UdpDatagram(
            sourceAddress = buf.copyOfRange(12, 16),
            destinationAddress = buf.copyOfRange(16, 20),
            sourcePort = u16(buf, ihl),
            destinationPort = u16(buf, ihl + 2),
            payload = buf.copyOfRange(payloadStart, payloadStart + payloadLength),
        )
    }

    /** Builds an IPv4/UDP packet with valid IP and UDP checksums. */
    fun build(
        source: ByteArray,
        destination: ByteArray,
        sourcePort: Int,
        destinationPort: Int,
        payload: ByteArray,
    ): ByteArray {
        require(source.size == 4 && destination.size == 4) { "IPv4 addresses only" }
        val total = 20 + UDP_HEADER + payload.size
        require(total <= 0xFFFF) { "payload too large" }
        val p = ByteArray(total)
        p[0] = 0x45 // v4, IHL 5
        put16(p, 2, total)
        put16(p, 6, 0x4000) // don't fragment
        p[8] = 64 // TTL
        p[9] = PROTOCOL_UDP.toByte()
        source.copyInto(p, 12)
        destination.copyInto(p, 16)
        put16(p, 10, checksum(p, 0, 20, 0))

        put16(p, 20, sourcePort)
        put16(p, 22, destinationPort)
        put16(p, 24, UDP_HEADER + payload.size)
        payload.copyInto(p, 28)
        var udpSum = pseudoHeaderSum(source, destination, UDP_HEADER + payload.size)
        udpSum = checksum(p, 20, UDP_HEADER + payload.size, udpSum)
        put16(p, 26, if (udpSum == 0) 0xFFFF else udpSum)
        return p
    }

    /** Builds the reply to [request]: addresses and ports swapped. */
    fun reply(request: UdpDatagram, payload: ByteArray): ByteArray = build(
        source = request.destinationAddress,
        destination = request.sourceAddress,
        sourcePort = request.destinationPort,
        destinationPort = request.sourcePort,
        payload = payload,
    )

    /** One's-complement sum; returns the final checksum value. */
    fun checksum(buf: ByteArray, offset: Int, length: Int, initial: Int): Int {
        var sum = initial.toLong()
        var i = offset
        val end = offset + length
        while (i + 1 < end) {
            sum += u16(buf, i)
            i += 2
        }
        if (i < end) sum += (buf[i].toInt() and 0xFF) shl 8
        while (sum shr 16 != 0L) sum = (sum and 0xFFFF) + (sum shr 16)
        return (sum.inv() and 0xFFFF).toInt()
    }

    private fun pseudoHeaderSum(src: ByteArray, dst: ByteArray, udpLength: Int): Int {
        // Returned as an *uncomplemented* partial sum for checksum()'s initial.
        var sum = 0L
        sum += u16(src, 0) + u16(src, 2) + u16(dst, 0) + u16(dst, 2)
        sum += PROTOCOL_UDP + udpLength
        while (sum shr 16 != 0L) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.toInt()
    }

    internal fun u16(b: ByteArray, i: Int) = ((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF)

    internal fun put16(b: ByteArray, i: Int, v: Int) {
        b[i] = (v ushr 8).toByte()
        b[i + 1] = v.toByte()
    }
}
