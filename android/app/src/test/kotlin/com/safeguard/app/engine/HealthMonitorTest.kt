package com.safeguard.app.engine

import com.safeguard.app.engine.health.Backoff
import com.safeguard.app.engine.health.HealthMonitorPolicy
import com.safeguard.app.engine.health.HealthReport
import com.safeguard.app.engine.health.MonitorAction
import com.safeguard.app.engine.health.MonitorObservation
import com.safeguard.app.engine.health.OverallHealth
import com.safeguard.app.engine.health.Repairable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthMonitorTest {
    private val min = 60_000L

    private fun obs(
        overall: OverallHealth,
        reason: String? = null,
        expected: Boolean = true,
        ai: Boolean = false,
        db: Boolean = false,
        lists: Boolean = false,
    ) = MonitorObservation(HealthReport(overall, emptyList(), reason), expected, ai, db, lists)

    @Test fun backoffGrowsAndIsCappedPerDay() {
        val b = Backoff()
        var now = 0L
        val gaps = ArrayList<Long>()
        repeat(10) {
            while (!b.canAttempt(now)) now += min
            gaps += now
            b.onAttempt(now)
            b.onFailure(now)
        }
        // 1, 4, 16, 64 min, then capped at 4 h; never more than 6 per 24 h.
        val deltas = gaps.zipWithNext { a, c -> (c - a) / min }
        assertEquals(listOf(1L, 4L, 16L, 64L, 240L), deltas.take(5))
        for (i in gaps.indices) {
            val inDay = gaps.count { it in gaps[i] until gaps[i] + 24 * 60 * min }
            assertTrue(inDay <= 6)
        }
    }

    @Test fun successResetsBackoff() {
        val b = Backoff()
        b.onAttempt(0); b.onFailure(0); b.onAttempt(min); b.onFailure(min)
        assertFalse(b.canAttempt(2 * min))
        b.onSuccess()
        assertTrue(b.canAttempt(2 * min))
    }

    @Test fun repairsBrokenComponentsWithBackoff() {
        val p = HealthMonitorPolicy()
        val a1 = p.evaluate(obs(OverallHealth.PARTIALLY_PROTECTED, "ai:model_unavailable", ai = true), 0)
        assertTrue(MonitorAction.Repair(Repairable.AI_MODEL) in a1)
        p.onRepairResult(Repairable.AI_MODEL, success = false, now = 0)
        // Within the backoff window: no new attempt.
        val a2 = p.evaluate(obs(OverallHealth.PARTIALLY_PROTECTED, "ai:model_unavailable", ai = true), 30_000)
        assertFalse(MonitorAction.Repair(Repairable.AI_MODEL) in a2)
        val a3 = p.evaluate(obs(OverallHealth.PARTIALLY_PROTECTED, "ai:model_unavailable", ai = true), min)
        assertTrue(MonitorAction.Repair(Repairable.AI_MODEL) in a3)
    }

    @Test fun notifiesOncePerDegradationAndClearsOnRecovery() {
        val p = HealthMonitorPolicy()
        val first = p.evaluate(obs(OverallHealth.NOT_PROTECTED, "vpn:revoked"), 0)
        assertTrue(first.any { it is MonitorAction.Notify })
        // Same problem 15 min later: no second notification.
        assertFalse(p.evaluate(obs(OverallHealth.NOT_PROTECTED, "vpn:revoked"), 15 * min).any { it is MonitorAction.Notify })
        // A different problem notifies again.
        assertTrue(p.evaluate(obs(OverallHealth.PARTIALLY_PROTECTED, "dns:private_dns"), 30 * min).any { it is MonitorAction.Notify })
        // Healthy → clear once.
        assertEquals(listOf(MonitorAction.ClearNotification), p.evaluate(obs(OverallHealth.PROTECTED), 45 * min))
        assertTrue(p.evaluate(obs(OverallHealth.PROTECTED), 60 * min).isEmpty())
    }

    @Test fun deliberateOffStatesNeitherNotifyNorRepair() {
        val p = HealthMonitorPolicy()
        val a = p.evaluate(obs(OverallHealth.NOT_PROTECTED, "paused", expected = false, ai = true, db = true), 0)
        assertTrue(a.isEmpty())
    }
}
