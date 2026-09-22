package com.safeguard.app.engine

import com.safeguard.app.engine.dns.DnsMessage
import com.safeguard.app.engine.dns.DnsPacketFilter
import com.safeguard.app.engine.dns.Ipv4Udp
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.InMemoryRuleStore
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class DnsFilterTest {
    private val app = byteArrayOf(10, 111, 222.toByte(), 1)
    private val dns = byteArrayOf(10, 111, 222.toByte(), 2)

    private fun queryPacket(name: String, id: Int = 0x1234, type: Int = 1) =
        Ipv4Udp.build(app, dns, 40000, 53, DnsMessage.buildQuery(id, name, type))

    private fun filter(policy: ProtectionPolicy, blocked: MutableList<Decision> = mutableListOf()): DnsPacketFilter {
        val store = InMemoryRuleStore().apply {
            upsert(Rule("adult.test", Category.SEXUAL, RuleAction.BLOCK, source = RuleSource.BUILT_IN))
        }
        return DnsPacketFilter(RuleEngine(store), { policy }, { blocked.add(it) })
    }

    @Test
    fun ipv4UdpRoundTripWithValidChecksums() {
        val payload = DnsMessage.buildQuery(7, "example.com")
        val packet = Ipv4Udp.build(app, dns, 5353, 53, payload)
        assertEquals(0, Ipv4Udp.checksum(packet, 0, 20, 0)) // IP header sums to zero
        val parsed = Ipv4Udp.parse(packet, packet.size)
        assertNotNull(parsed)
        parsed!!
        assertEquals(5353, parsed.sourcePort)
        assertEquals(53, parsed.destinationPort)
        assertArrayEquals(payload, parsed.payload)
    }

    @Test
    fun parsesQueryName() {
        val q = DnsMessage.parseQuery(DnsMessage.buildQuery(9, "WWW.Example.COM", type = 28))!!
        assertEquals("www.example.com", q.name)
        assertEquals(28, q.type)
        assertEquals(9, q.id)
    }

    @Test
    fun blockedQueryGetsNxdomainWithSameIdAndQuestion() {
        val blocked = mutableListOf<Decision>()
        val packet = queryPacket("www.adult.test", id = 0xBEEF)
        val out = filter(ProtectionPolicy.allCategories(), blocked).process(packet, packet.size)
        assertTrue(out is DnsPacketFilter.Outcome.Reply)
        val reply = Ipv4Udp.parse((out as DnsPacketFilter.Outcome.Reply).packet, out.packet.size)!!
        // Addresses and ports are swapped back to the app.
        assertArrayEquals(app, reply.destinationAddress)
        assertEquals(40000, reply.destinationPort)
        assertEquals(53, reply.sourcePort)
        val msg = reply.payload
        assertEquals(0xBEEF, DnsMessage.id(msg))
        val flags = Ipv4Udp.u16(msg, 2)
        assertTrue(flags and 0x8000 != 0) // QR
        assertEquals(DnsMessage.RCODE_NXDOMAIN, flags and 0xF)
        assertEquals(1, Ipv4Udp.u16(msg, 4))
        assertEquals(0, Ipv4Udp.u16(msg, 6))
        assertEquals(1, blocked.size)
        assertEquals(Category.SEXUAL, blocked[0].category)
    }

    @Test
    fun allowedQueryIsForwardedAndWrappedBack() {
        val packet = queryPacket("example.com")
        val out = filter(ProtectionPolicy.allCategories()).process(packet, packet.size)
        assertTrue(out is DnsPacketFilter.Outcome.Forward)
        val req = (out as DnsPacketFilter.Outcome.Forward).request
        assertEquals("example.com", req.query.name)
        val fakeAnswer = req.payload.copyOf().also { Ipv4Udp.put16(it, 2, 0x8180) }
        val wrappedPacket = req.wrap(fakeAnswer)
        val wrapped = Ipv4Udp.parse(wrappedPacket, wrappedPacket.size)!!
        assertArrayEquals(fakeAnswer, wrapped.payload)
        assertArrayEquals(app, wrapped.destinationAddress)
        // SERVFAIL fallback for offline.
        val failPacket = req.failure()
        val fail = Ipv4Udp.parse(failPacket, failPacket.size)!!
        assertEquals(DnsMessage.RCODE_SERVFAIL, Ipv4Udp.u16(fail.payload, 2) and 0xF)
    }

    @Test
    fun protectionOffForwardsBlockedDomains() {
        val packet = queryPacket("adult.test")
        val out = filter(ProtectionPolicy.DISABLED).process(packet, packet.size)
        assertTrue(out is DnsPacketFilter.Outcome.Forward)
    }

    @Test
    fun nonDnsTrafficIsDropped() {
        val f = filter(ProtectionPolicy.allCategories())
        val otherPort = Ipv4Udp.build(app, dns, 40000, 123, DnsMessage.buildQuery(1, "adult.test"))
        assertSame(DnsPacketFilter.Outcome.Drop, f.process(otherPort, otherPort.size))
        val tcp = queryPacket("adult.test").also { it[9] = 6 }
        assertSame(DnsPacketFilter.Outcome.Drop, f.process(tcp, tcp.size))
        val ipv6 = queryPacket("adult.test").also { it[0] = 0x60 }
        assertSame(DnsPacketFilter.Outcome.Drop, f.process(ipv6, ipv6.size))
    }

    @Test
    fun responsesAndMultiQuestionMessagesAreRejected() {
        val response = DnsMessage.buildQuery(1, "adult.test").also { Ipv4Udp.put16(it, 2, 0x8100) }
        assertNull(DnsMessage.parseQuery(response))
        val twoQuestions = DnsMessage.buildQuery(1, "adult.test").also { Ipv4Udp.put16(it, 4, 2) }
        assertNull(DnsMessage.parseQuery(twoQuestions))
    }

    @Test
    fun compressionLoopsAndOutOfBoundsPointersAreRejected() {
        val loop = ByteArray(DnsMessage.HEADER + 6).also {
            Ipv4Udp.put16(it, 4, 1)
            it[12] = 0xC0.toByte(); it[13] = 12 // points at itself
        }
        assertNull(DnsMessage.parseQuery(loop))
        val oob = ByteArray(DnsMessage.HEADER + 6).also {
            Ipv4Udp.put16(it, 4, 1)
            it[12] = 40 // label longer than the message
        }
        assertNull(DnsMessage.parseQuery(oob))
    }

    @Test
    fun truncatedAndFragmentedPacketsAreDropped() {
        val f = filter(ProtectionPolicy.allCategories())
        val packet = queryPacket("adult.test")
        assertSame(DnsPacketFilter.Outcome.Drop, f.process(packet, 25))
        val fragmented = packet.copyOf().also { it[6] = 0x20 } // MF flag
        assertSame(DnsPacketFilter.Outcome.Drop, f.process(fragmented, fragmented.size))
    }

    @Test
    fun randomGarbageNeverThrows() {
        val f = filter(ProtectionPolicy.allCategories())
        val rnd = Random(42)
        repeat(20_000) {
            val size = rnd.nextInt(0, 600)
            val buf = rnd.nextBytes(size)
            if (size > 0 && rnd.nextBoolean()) buf[0] = 0x45
            f.process(buf, size)
        }
        // Also fuzz only the DNS payload inside a valid IP/UDP envelope.
        repeat(20_000) {
            val payload = rnd.nextBytes(rnd.nextInt(0, 300))
            val p = Ipv4Udp.build(app, dns, 1000, 53, payload)
            f.process(p, p.size)
        }
    }
}
