package com.safeguard.app.engine.dns

import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.RuleEngine

/** Receives every BLOCK decision (for logging/statistics). */
fun interface BlockListener {
    fun onBlocked(decision: Decision)
}

/**
 * Turns one packet from the tun interface into an action. Pure logic: no
 * sockets, no Android — the VPN service does the I/O.
 */
class DnsPacketFilter(
    private val engine: RuleEngine,
    private val policy: () -> ProtectionPolicy,
    private val listener: BlockListener,
    private val dnsPort: Int = 53,
) {
    sealed interface Outcome {
        /** Write this packet back to the tun interface. */
        class Reply(val packet: ByteArray, val decision: Decision) : Outcome

        /** Send [query] upstream and wrap the answer with [ForwardRequest.wrap]. */
        class Forward(val request: ForwardRequest) : Outcome

        /** Not a DNS query we handle (TCP, fragments, garbage): discard. */
        data object Drop : Outcome
    }

    class ForwardRequest(
        val datagram: UdpDatagram,
        val query: DnsQuery,
        val decision: Decision,
    ) {
        val payload: ByteArray get() = datagram.payload

        /** Wraps an upstream answer into a packet for the requesting app. */
        fun wrap(response: ByteArray): ByteArray = Ipv4Udp.reply(datagram, response)

        /** SERVFAIL for when no upstream answered (offline, airplane mode). */
        fun failure(): ByteArray =
            Ipv4Udp.reply(datagram, DnsMessage.errorResponse(payload, query, DnsMessage.RCODE_SERVFAIL))
    }

    fun process(buf: ByteArray, length: Int): Outcome {
        val datagram = Ipv4Udp.parse(buf, length) ?: return Outcome.Drop
        if (datagram.destinationPort != dnsPort) return Outcome.Drop
        val query = DnsMessage.parseQuery(datagram.payload) ?: return Outcome.Drop

        val decision = engine.evaluate(query.name, policy())
        if (decision.isBlocked) {
            listener.onBlocked(decision)
            val answer = DnsMessage.errorResponse(datagram.payload, query, DnsMessage.RCODE_NXDOMAIN)
            return Outcome.Reply(Ipv4Udp.reply(datagram, answer), decision)
        }
        return Outcome.Forward(ForwardRequest(datagram, query, decision))
    }
}
