package com.safeguard.app.engine

import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.InMemoryBlockEventStore
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.DecisionReason
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.search.NoOpSearchFilterService
import com.safeguard.app.engine.search.SearchQuery
import com.safeguard.app.engine.stats.StatisticsService
import com.safeguard.app.engine.status.ProtectionStatusHolder
import com.safeguard.app.engine.status.VpnState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.TimeZone

class LoggingStatusTest {
    private val direct = java.util.concurrent.Executor { it.run() }
    private fun blocked(domain: String, category: Category = Category.SEXUAL) =
        Decision(RuleAction.BLOCK, category, DecisionReason.CATEGORY_BLOCKED, domain)

    @Test
    fun logsOnlyTimestampDomainCategory() {
        val store = InMemoryBlockEventStore()
        BlockLogger(store, direct, clock = { 1000L }).onBlocked(blocked("adult.test"))
        assertEquals(listOf(BlockEvent(1000L, "adult.test", Category.SEXUAL)), store.recent(10))
    }

    @Test
    fun repeatedLookupsWithinWindowCountOnce() {
        var now = 0L
        val store = InMemoryBlockEventStore()
        val logger = BlockLogger(store, direct, clock = { now }, dedupeWindowMs = 30_000)
        repeat(5) { logger.onBlocked(blocked("adult.test")) } // A, AAAA, retries
        logger.onBlocked(blocked("casino.test", Category.GAMBLING))
        now = 31_000
        logger.onBlocked(blocked("adult.test"))
        assertEquals(3, store.recent(10).size)
    }

    @Test
    fun decisionsWithoutDomainAreIgnored() {
        val store = InMemoryBlockEventStore()
        BlockLogger(store, direct).onBlocked(Decision(RuleAction.BLOCK, Category.UNKNOWN, DecisionReason.UNKNOWN_BLOCKED_STRICT, null))
        assertEquals(0, store.recent(10).size)
    }

    @Test
    fun pruneRespectsRetentionAndRowCap() {
        val store = InMemoryBlockEventStore()
        (1..10).forEach { store.insert(BlockEvent(it * 100L, "d$it.test", Category.DRUGS)) }
        store.prune(before = 300, maxRows = 5)
        assertEquals(5, store.recent(100).size)
        assertTrue(store.recent(100).all { it.timestamp >= 600 })
        assertEquals(10, store.lifetimeTotal()) // lifetime counter survives pruning
        store.clear()
        assertEquals(0, store.lifetimeTotal())
    }

    @Test
    fun statisticsTodayWeekTotalAndByCategory() {
        val zone = ZoneOffset.UTC
        val now = LocalDateTime.of(2026, 9, 22, 12, 0).toInstant(zone).toEpochMilli()
        val hour = 3_600_000L
        val store = InMemoryBlockEventStore()
        store.insert(BlockEvent(now - 1 * hour, "a.test", Category.SEXUAL)) // today
        store.insert(BlockEvent(now - 11 * hour, "b.test", Category.SEXUAL)) // today (01:00)
        store.insert(BlockEvent(now - 13 * hour, "c.test", Category.GAMBLING)) // yesterday
        store.insert(BlockEvent(now - 6 * 24 * hour, "d.test", Category.DRUGS)) // this week
        store.insert(BlockEvent(now - 10 * 24 * hour, "e.test", Category.VIOLENCE)) // older
        val stats = StatisticsService(store, { now }, { TimeZone.getTimeZone("UTC") }).compute()
        assertEquals(2, stats.today)
        assertEquals(4, stats.last7Days)
        assertEquals(5L, stats.total)
        assertEquals(2, stats.byCategory[Category.SEXUAL])
        assertEquals(1, stats.byCategory[Category.VIOLENCE])
        assertNull(stats.byCategory[Category.GORE])
    }

    @Test
    fun statisticsTodayUsesLocalMidnightOfTheGivenZone() {
        // 2026-09-22 01:30 in Riyadh (UTC+3) = 2026-09-21 22:30 UTC.
        val riyadh = TimeZone.getTimeZone("Asia/Riyadh")
        val now = LocalDateTime.of(2026, 9, 21, 22, 30).toInstant(ZoneOffset.UTC).toEpochMilli()
        val minute = 60_000L
        val store = InMemoryBlockEventStore()
        store.insert(BlockEvent(now - 60 * minute, "a.test", Category.SEXUAL)) // 00:30 local: today
        store.insert(BlockEvent(now - 120 * minute, "b.test", Category.SEXUAL)) // 23:30 local yesterday
        assertEquals(1, StatisticsService(store, { now }, { riyadh }).compute().today)
        assertEquals(2, StatisticsService(store, { now }, { TimeZone.getTimeZone("UTC") }).compute().today)
    }

    @Test
    fun vpnStateTransitions() {
        val holder = ProtectionStatusHolder()
        val seen = mutableListOf<VpnState>()
        holder.addListener { seen.add(it.vpnState) }

        holder.starting()
        holder.update { it.copy(rulesReady = true, ruleCount = 3) }
        holder.running(now = 42)
        assertTrue(holder.current.isActive)
        assertEquals(42L, holder.current.startedAt)

        holder.revoked()
        assertFalse(holder.current.isActive)
        assertFalse(holder.current.dnsFilterActive)

        holder.failed("establish() returned null")
        assertEquals("establish() returned null", holder.current.lastError)
        holder.starting()
        assertNull(holder.current.lastError)

        holder.stopped()
        holder.stopped() // no-op: listeners not called for identical state
        assertEquals(
            listOf(VpnState.STARTING, VpnState.STARTING, VpnState.RUNNING, VpnState.REVOKED, VpnState.ERROR, VpnState.STARTING, VpnState.STOPPED),
            seen,
        )
        assertEquals("stopped", holder.current.toMap()["vpnState"])
    }

    @Test
    fun activeRequiresVpnDnsAndRules() {
        val holder = ProtectionStatusHolder()
        holder.running(1)
        assertFalse("rules not loaded yet", holder.current.isActive)
        holder.update { it.copy(rulesReady = true) }
        assertTrue(holder.current.isActive)
    }

    @Test
    fun searchFilterPlaceholderIsInactive() {
        assertFalse(NoOpSearchFilterService.isActive)
        assertEquals(RuleAction.ALLOW, NoOpSearchFilterService.classify(SearchQuery("google", "anything")).action)
    }

    // Regression (B1): onDestroy runs shutdown() a second time after revoke,
    // stop, errors and missing consent. That must not overwrite the final
    // state with STOPPING (UI stuck on "starting", no restart button).
    @Test
    fun stoppingOnlyAppliesToALiveVpn() {
        val holder = ProtectionStatusHolder()
        holder.running(1)
        holder.revoked()
        holder.stopping()
        assertEquals(VpnState.REVOKED, holder.current.vpnState)

        holder.failed("establish failed")
        holder.stopping()
        assertEquals(VpnState.ERROR, holder.current.vpnState)
        assertEquals("establish failed", holder.current.lastError)

        holder.permissionRequired()
        holder.stopping()
        assertEquals(VpnState.PERMISSION_REQUIRED, holder.current.vpnState)

        holder.stopped()
        holder.stopping()
        assertEquals(VpnState.STOPPED, holder.current.vpnState)

        holder.starting()
        holder.stopping()
        assertEquals(VpnState.STOPPING, holder.current.vpnState)
    }

    // Regression (B3): a status refresh from Flutter must not reset the
    // network facts reported by the VPN (false "no network" warning).
    @Test
    fun environmentRefreshKeepsUpstreamFacts() {
        val holder = ProtectionStatusHolder()
        holder.running(1)
        holder.upstreamChanged(available = true, privateDnsStrict = true)
        holder.environmentChanged(otherVpnActive = false)
        assertTrue(holder.current.upstreamAvailable)
        assertTrue(holder.current.privateDnsStrict)

        holder.upstreamChanged(available = false, privateDnsStrict = false) // airplane mode
        assertFalse(holder.current.upstreamAvailable)

        holder.revoked()
        assertFalse("stale network facts cleared when the VPN stops", holder.current.upstreamAvailable)
    }

    @Test
    fun recordedEventsBumpTheLiveActivityVersion() {
        val store = InMemoryBlockEventStore()
        val logger = BlockLogger(store, direct, clock = { 1000L })
        val status = ProtectionStatusHolder()
        var pushed = 0
        status.addListener { pushed++ }
        logger.onRecorded = { status.activityChanged() }
        logger.onBlocked(blocked("adult.test"))
        logger.onBlocked(blocked("casino.test"))
        assertEquals(2L, status.current.activityVersion)
        assertEquals(2, pushed)
        assertEquals(2L, status.current.toMap()["activityVersion"])
        // Nothing stored (log off) → no pulse.
        val off = BlockLogger(store, direct, retention = { com.safeguard.app.engine.logging.LogRetention.NEVER })
        off.onRecorded = { status.activityChanged() }
        off.onBlocked(blocked("other.test"))
        assertEquals(2L, status.current.activityVersion)
    }
}
