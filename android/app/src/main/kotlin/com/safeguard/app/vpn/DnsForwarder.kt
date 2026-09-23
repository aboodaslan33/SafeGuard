package com.safeguard.app.vpn

import android.net.VpnService
import com.safeguard.app.engine.dns.DnsMessage
import com.safeguard.app.engine.dns.DnsPacketFilter
import com.safeguard.app.engine.health.UpstreamHealth
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Sends allowed queries to the network's own DNS resolver — the same server
 * the device would use without SafeGuard — and returns the answer.
 *
 * Sockets are `protect()`ed and bound to the physical network so they never
 * loop back into the VPN. The executor is bounded: under a flood, the
 * oldest pending queries are dropped (clients retry) instead of growing
 * memory without limit.
 */
class DnsForwarder(
    private val vpn: VpnService,
    private val upstream: () -> UpstreamNetwork?,
    private val health: UpstreamHealth? = null,
) {
    private val executor = ThreadPoolExecutor(
        2, 8, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue(256),
        { r -> Thread(r, "sg-dns-forward").apply { isDaemon = true } },
        ThreadPoolExecutor.DiscardOldestPolicy(),
    )

    fun forward(request: DnsPacketFilter.ForwardRequest, write: (ByteArray) -> Unit) {
        executor.execute {
            val answer = resolve(request.upstreamPayload)
            write(if (answer != null) request.wrap(answer) else request.failure())
        }
    }

    fun shutdown() {
        executor.shutdownNow()
    }

    private fun resolve(query: ByteArray): ByteArray? {
        val net = upstream() ?: return null // offline: SERVFAIL, fast (not a failure)
        val answer = resolveOn(net, query)
        val now = System.currentTimeMillis()
        if (answer != null) health?.success(now) else health?.failure(now)
        return answer
    }

    private fun resolveOn(net: UpstreamNetwork, query: ByteArray): ByteArray? {
        val servers = net.dnsServers.ifEmpty { FALLBACK }
        val queryId = DnsMessage.id(query)
        for (server in servers.take(MAX_SERVERS)) {
            try {
                DatagramSocket().use { socket ->
                    if (!vpn.protect(socket)) return@use
                    try {
                        net.network.bindSocket(socket)
                    } catch (e: IOException) {
                        // Network just went away; the next server/attempt may work.
                    }
                    socket.soTimeout = TIMEOUT_MS
                    socket.send(DatagramPacket(query, query.size, InetSocketAddress(server, 53)))
                    val buf = ByteArray(MAX_RESPONSE)
                    val packet = DatagramPacket(buf, buf.size)
                    socket.receive(packet)
                    val answer = buf.copyOf(packet.length)
                    // Ignore anything that isn't the answer to this query.
                    if (DnsMessage.id(answer) == queryId && packet.length >= DnsMessage.HEADER) {
                        return fitToMtu(answer)
                    }
                }
            } catch (e: IOException) {
                // Timeout or unreachable: try the next server.
            }
        }
        return null
    }

    /**
     * Answers larger than one packet on our tun MTU are truncated to the
     * question with the TC bit set; the resolver then retries (TCP DNS to
     * SafeGuard is not supported — documented limitation).
     */
    private fun fitToMtu(answer: ByteArray): ByteArray {
        if (answer.size <= MAX_UDP_PAYLOAD) return answer
        val q = DnsMessage.parseQuery(answer.copyOf().also { it[2] = (it[2].toInt() and 0x7F).toByte() })
            ?: return answer.copyOf(DnsMessage.HEADER)
        val truncated = answer.copyOf(q.questionEnd)
        truncated[2] = (truncated[2].toInt() or 0x82).toByte() // QR + TC
        for (i in 6 until 12) truncated[i] = 0
        return truncated
    }

    private companion object {
        const val TIMEOUT_MS = 3000
        const val MAX_SERVERS = 2
        const val MAX_RESPONSE = 4096
        const val MAX_UDP_PAYLOAD = SafeGuardVpnService.MTU - 28

        /**
         * Used only if the network reports no DNS servers at all (rare).
         * Documented in the README: this is the one case where queries go
         * to a public resolver instead of the network's own.
         */
        val FALLBACK: List<InetAddress> = listOf(
            InetAddress.getByAddress(byteArrayOf(1, 1, 1, 1)),
            InetAddress.getByAddress(byteArrayOf(9, 9, 9, 9)),
        )
    }
}
