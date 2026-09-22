package com.safeguard.app.engine

import com.safeguard.app.engine.apps.AccessibilityState
import com.safeguard.app.engine.apps.AccessibilityStateResolver
import com.safeguard.app.engine.apps.AppAction
import com.safeguard.app.engine.apps.AppProtection
import com.safeguard.app.engine.apps.AppRuleError
import com.safeguard.app.engine.apps.AppRuleException
import com.safeguard.app.engine.apps.InMemoryProtectedAppStore
import com.safeguard.app.engine.dns.DnsMessage
import com.safeguard.app.engine.dns.DnsPacketFilter
import com.safeguard.app.engine.dns.DnsRecords
import com.safeguard.app.engine.dns.Ipv4Udp
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.InMemoryRuleStore
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.safesearch.SafeSearchRewriter
import com.safeguard.app.engine.safesearch.YouTubeMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SafeSearchTest {
    private val on = SafeSearchConfig(enabled = true)
    private val app = byteArrayOf(10, 111, 222.toByte(), 1)
    private val dns = byteArrayOf(10, 111, 222.toByte(), 2)

    @Test fun mapsOnlySearchFrontEnds() {
        for (n in listOf("google.com", "www.google.com", "www.google.com.sa", "www.google.co.uk", "google.de")) {
            assertEquals(n, SafeSearchRewriter.GOOGLE_TARGET, SafeSearchRewriter.targetFor(n, on))
        }
        for (n in listOf("mail.google.com", "maps.google.com", "google.org", "notgoogle.com", "www.google.com.evil.net", "forcesafesearch.google.com", "googleapis.com")) {
            assertNull(n, SafeSearchRewriter.targetFor(n, on))
        }
        assertEquals(SafeSearchRewriter.BING_TARGET, SafeSearchRewriter.targetFor("www.bing.com", on))
        assertEquals(SafeSearchRewriter.DDG_TARGET, SafeSearchRewriter.targetFor("duckduckgo.com", on))
        assertEquals(SafeSearchRewriter.YOUTUBE_STRICT_TARGET, SafeSearchRewriter.targetFor("m.youtube.com", on))
    }

    @Test fun perEngineSettings() {
        assertNull(SafeSearchRewriter.targetFor("www.google.com", SafeSearchConfig.OFF))
        assertNull(SafeSearchRewriter.targetFor("www.google.com", on.copy(google = false)))
        assertNull(SafeSearchRewriter.targetFor("www.youtube.com", on.copy(youtube = YouTubeMode.OFF)))
        assertEquals(
            SafeSearchRewriter.YOUTUBE_MODERATE_TARGET,
            SafeSearchRewriter.targetFor("www.youtube.com", on.copy(youtube = YouTubeMode.MODERATE)),
        )
    }

    private fun filter(config: SafeSearchConfig, policy: ProtectionPolicy = ProtectionPolicy.allCategories()): DnsPacketFilter {
        val store = InMemoryRuleStore().apply {
            upsert(Rule("www.bing.com", Category.SEXUAL, RuleAction.BLOCK, source = RuleSource.USER))
        }
        return DnsPacketFilter(RuleEngine(store), { policy }, {}, safeSearch = { config })
    }

    /** Upstream answer for forcesafesearch.google.com using a compression pointer. */
    private fun upstreamAnswer(id: Int): ByteArray {
        val q = DnsMessage.buildQuery(id, SafeSearchRewriter.GOOGLE_TARGET)
        val answer = byteArrayOf(
            0xC0.toByte(), 12, 0, 1, 0, 1, 0, 0, 0x0E, 0x10, 0, 4, 216.toByte(), 239.toByte(), 38, 120,
        )
        return (q + answer).also {
            Ipv4Udp.put16(it, 2, 0x8180)
            Ipv4Udp.put16(it, 6, 1)
        }
    }

    @Test fun googleQueryIsAnsweredWithCnameToSafeSearch() {
        val packet = Ipv4Udp.build(app, dns, 40000, 53, DnsMessage.buildQuery(0x4242, "www.google.com"))
        val out = filter(on).process(packet, packet.size) as DnsPacketFilter.Outcome.Forward
        val req = out.request
        assertEquals(SafeSearchRewriter.GOOGLE_TARGET, DnsMessage.parseQuery(req.upstreamPayload)!!.name)
        assertEquals(0x4242, DnsMessage.id(req.upstreamPayload))

        val reply = req.wrap(upstreamAnswer(0x4242))
        val msg = Ipv4Udp.parse(reply, reply.size)!!.payload
        assertEquals(0x4242, DnsMessage.id(msg))
        assertEquals("www.google.com", DnsMessage.parseQuery(msg.copyOf().also { it[2] = 0 })!!.name)
        val (rcode, records) = DnsRecords.parseAnswers(msg)!!
        assertEquals(0, rcode)
        assertEquals(DnsRecords.TYPE_CNAME, records[0].type)
        assertEquals("www.google.com", DnsRecords.nameToString(records[0].name))
        assertEquals(SafeSearchRewriter.GOOGLE_TARGET, DnsRecords.nameToString(records[0].rdataName!!))
        assertEquals(DnsRecords.TYPE_A, records[1].type)
        assertEquals(listOf(216, 239, 38, 120), records[1].rdata.map { it.toInt() and 0xFF })
    }

    @Test fun malformedUpstreamGivesServfailNotTheUnfilteredName() {
        val packet = Ipv4Udp.build(app, dns, 40000, 53, DnsMessage.buildQuery(7, "www.google.com"))
        val req = (filter(on).process(packet, packet.size) as DnsPacketFilter.Outcome.Forward).request
        val reply = req.wrap(byteArrayOf(0, 7, 0x81.toByte()))
        val msg = Ipv4Udp.parse(reply, reply.size)!!.payload
        assertEquals(DnsMessage.RCODE_SERVFAIL, Ipv4Udp.u16(msg, 2) and 0xF)
    }

    @Test fun httpsRecordsForMappedNamesGetNoData() {
        val packet = Ipv4Udp.build(app, dns, 40000, 53, DnsMessage.buildQuery(9, "www.google.com", type = 65))
        val out = filter(on).process(packet, packet.size)
        assertTrue(out is DnsPacketFilter.Outcome.Reply)
        val msg = Ipv4Udp.parse((out as DnsPacketFilter.Outcome.Reply).packet, out.packet.size)!!.payload
        assertEquals(0, Ipv4Udp.u16(msg, 2) and 0xF)
        assertEquals(0, Ipv4Udp.u16(msg, 6))
    }

    @Test fun blockRulesStillWinAndOffMeansPassThrough() {
        val bing = Ipv4Udp.build(app, dns, 40000, 53, DnsMessage.buildQuery(1, "www.bing.com"))
        assertTrue(filter(on).process(bing, bing.size) is DnsPacketFilter.Outcome.Reply) // user-blocked: NXDOMAIN
        val google = Ipv4Udp.build(app, dns, 40000, 53, DnsMessage.buildQuery(1, "www.google.com"))
        val off = filter(SafeSearchConfig.OFF).process(google, google.size) as DnsPacketFilter.Outcome.Forward
        assertNull(off.request.safeSearchTarget)
        val paused = filter(on, ProtectionPolicy.DISABLED).process(google, google.size) as DnsPacketFilter.Outcome.Forward
        assertNull(paused.request.safeSearchTarget)
    }
}

class AppProtectionTest {
    private val installed = setOf("com.example.social", "com.example.game", "com.launcher.home")
    private fun protection(store: InMemoryProtectedAppStore = InMemoryProtectedAppStore()) =
        AppProtection(store, { it in installed }, { setOf("com.launcher.home") }, clock = { 5 })

    private fun expect(error: AppRuleError, block: () -> Unit) {
        try {
            block(); fail("expected $error")
        } catch (e: AppRuleException) {
            assertEquals(error, e.error)
        }
    }

    @Test fun protectedAndUnprotectedPackages() {
        val p = protection()
        p.add("com.example.social")
        assertEquals(AppAction.BLOCK_APP, p.decide("com.example.social", true).action)
        assertEquals(AppAction.ALLOW, p.decide("com.example.game", true).action)
        assertEquals(AppAction.ALLOW, p.decide(null, true).action)
        assertEquals("protection_off", p.decide("com.example.social", false).reason)
    }

    @Test fun addingAndRemoving() {
        val p = protection()
        assertEquals(5L, p.add(" com.example.game ").addedAt)
        assertEquals(listOf("com.example.game"), p.list().map { it.packageName })
        assertTrue(p.remove("com.example.game"))
        assertFalse(p.remove("com.example.game"))
        assertEquals(AppAction.ALLOW, p.decide("com.example.game", true).action)
    }

    @Test fun duplicateInvalidNotInstalledAndExempt() {
        val p = protection()
        p.add("com.example.social")
        expect(AppRuleError.DUPLICATE) { p.add("com.example.social") }
        for (bad in listOf("", "social", "1com.x", "com..x", "com.x;rm", "../etc", "com.x y")) {
            expect(AppRuleError.INVALID_PACKAGE) { p.add(bad) }
        }
        expect(AppRuleError.NOT_INSTALLED) { p.add("com.not.installed") }
        for (exempt in listOf("com.safeguard.app", "com.android.settings", "com.android.systemui", "com.launcher.home", "com.android.phone")) {
            expect(AppRuleError.NOT_ALLOWED) { p.add(exempt) }
        }
    }

    @Test fun exemptAppsAreNeverBlockedEvenIfStored() {
        val store = InMemoryProtectedAppStore()
        store.add(com.safeguard.app.engine.apps.ProtectedApp("com.android.settings", 0))
        assertEquals(AppAction.ALLOW, protection(store).decide("com.android.settings", true).action)
    }

    @Test fun limitIsEnforced() {
        val p = AppProtection(InMemoryProtectedAppStore(), { true }, { emptySet() }, maxApps = 1)
        p.add("com.a.one")
        expect(AppRuleError.LIMIT_REACHED) { p.add("com.a.two") }
    }
}

class AccessibilityStateTest {
    private val ours = "com.safeguard.app/com.safeguard.app.apps.AppGuardService"

    @Test fun serviceUnavailable() =
        assertEquals(AccessibilityState.UNAVAILABLE, AccessibilityStateResolver.resolve(false, ours, ours, false))

    @Test fun serviceEnabledInLongAndShortForm() {
        assertEquals(AccessibilityState.ENABLED, AccessibilityStateResolver.resolve(true, "a/b:$ours", ours, false))
        assertEquals(
            AccessibilityState.ENABLED,
            AccessibilityStateResolver.resolve(true, "com.safeguard.app/.apps.AppGuardService", ours, true),
        )
    }

    @Test fun serviceDisabled() {
        assertEquals(AccessibilityState.DISABLED, AccessibilityStateResolver.resolve(true, null, ours, false))
        assertEquals(AccessibilityState.DISABLED, AccessibilityStateResolver.resolve(true, "other/.Svc", ours, false))
    }

    @Test fun permissionDenied() =
        assertEquals(AccessibilityState.PERMISSION_DENIED, AccessibilityStateResolver.resolve(true, "", ours, true))
}
