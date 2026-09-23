package com.safeguard.app.engine.dns

import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.safesearch.SafeSearchRewriter

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
    /** SafeSearch enforcement; OFF unless Search Protection is on. */
    private val safeSearch: () -> SafeSearchConfig = { SafeSearchConfig.OFF },
    /** Sees every decision (allow and block), e.g. the debug trace. */
    private val observer: (Decision) -> Unit = {},
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
        /** What to send upstream (differs from [payload] for SafeSearch). */
        val upstreamPayload: ByteArray = datagram.payload,
        /** SafeSearch rewrite target, if any. */
        val safeSearchTarget: String? = null,
    ) {
        val payload: ByteArray get() = datagram.payload

        /**
         * Wraps an upstream answer into a packet for the requesting app. For
         * SafeSearch the answer is rebuilt as `name CNAME target` + records;
         * if that fails the app gets SERVFAIL, never the unfiltered name.
         */
        fun wrap(response: ByteArray): ByteArray {
            val target = safeSearchTarget ?: return Ipv4Udp.reply(datagram, response)
            val rebuilt = DnsRecords.synthesizeCname(payload, query, target, response) ?: return failure()
            return Ipv4Udp.reply(datagram, rebuilt)
        }

        /** SERVFAIL for when no upstream answered (offline, airplane mode). */
        fun failure(): ByteArray =
            Ipv4Udp.reply(datagram, DnsMessage.errorResponse(payload, query, DnsMessage.RCODE_SERVFAIL))
    }

    fun process(buf: ByteArray, length: Int): Outcome {
        val datagram = Ipv4Udp.parse(buf, length) ?: return Outcome.Drop
        if (datagram.destinationPort != dnsPort) return Outcome.Drop
        val query = DnsMessage.parseQuery(datagram.payload) ?: return Outcome.Drop

        val decision = engine.evaluate(query.name, policy())
        observer(decision)
        if (decision.isBlocked) {
            listener.onBlocked(decision)
            val answer = DnsMessage.errorResponse(datagram.payload, query, DnsMessage.RCODE_NXDOMAIN)
            return Outcome.Reply(Ipv4Udp.reply(datagram, answer), decision)
        }
        val policy = policy()
        val target = if (policy.enabled) SafeSearchRewriter.targetFor(query.name, safeSearch()) else null
        if (target != null) {
            return when (query.type) {
                DnsRecords.TYPE_A, DnsRecords.TYPE_AAAA, DnsRecords.TYPE_CNAME, TYPE_ANY -> {
                    val upstream = DnsMessage.buildQuery(query.id, target, query.type)
                    Outcome.Forward(ForwardRequest(datagram, query, decision, upstream, target))
                }
                // HTTPS/SVCB records could carry address hints for the
                // unrestricted endpoint: answer "no records" instead.
                else -> Outcome.Reply(Ipv4Udp.reply(datagram, DnsRecords.noData(datagram.payload, query)), decision)
            }
        }
        return Outcome.Forward(ForwardRequest(datagram, query, decision))
    }

    private companion object {
        const val TYPE_ANY = 255
    }
}
