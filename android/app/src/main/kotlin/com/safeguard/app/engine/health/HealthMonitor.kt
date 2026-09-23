package com.safeguard.app.engine.health

/**
 * Exponential backoff with a daily cap, for recovery attempts that cost
 * battery or I/O. Default: 1 min, 4 min, 16 min, … capped at 4 h, and at
 * most 6 attempts in any 24 h — so a component that stays broken can't
 * cause a restart loop.
 */
class Backoff(
    private val baseMs: Long = 60_000,
    private val factor: Int = 4,
    private val maxDelayMs: Long = 4 * 60 * 60_000L,
    private val maxPerDay: Int = 6,
) {
    private var failures = 0
    private var nextAllowedAt = 0L
    private val attempts = ArrayDeque<Long>()

    @Synchronized
    fun canAttempt(now: Long): Boolean {
        while (attempts.isNotEmpty() && now - attempts.first() >= DAY_MS) attempts.removeFirst()
        return now >= nextAllowedAt && attempts.size < maxPerDay
    }

    @Synchronized
    fun onAttempt(now: Long) {
        attempts.addLast(now)
    }

    @Synchronized
    fun onFailure(now: Long) {
        var delay = baseMs
        repeat(failures) { delay = (delay * factor).coerceAtMost(maxDelayMs) }
        nextAllowedAt = now + delay
        failures++
    }

    @Synchronized
    fun onSuccess() {
        failures = 0
        nextAllowedAt = 0
    }

    private companion object {
        const val DAY_MS = 24 * 60 * 60_000L
    }
}

/** Components the monitor can try to repair itself (the VPN has its own policy). */
enum class Repairable { AI_MODEL, DATABASE, BUNDLED_LISTS }

sealed interface MonitorAction {
    data class Repair(val component: Repairable) : MonitorAction

    /** Tell the user protection is degraded; [reason] is a stable id. */
    data class Notify(val overall: OverallHealth, val reason: String) : MonitorAction

    /** Protection is healthy again: remove the degraded notification. */
    data object ClearNotification : MonitorAction
}

/** What the Android layer observed in one check. */
data class MonitorObservation(
    val report: HealthReport,
    /** The user turned protection on (and it isn't in Safe Mode / paused). */
    val protectionExpected: Boolean,
    val aiModelBroken: Boolean,
    val databaseFailing: Boolean,
    val bundledListsMissing: Boolean,
)

/**
 * Pure policy behind the continuous health monitor: detect → repair (with
 * backoff) → re-check → report → notify once per degradation.
 *
 * Never reports healthy on its own: the overall status always comes from
 * [ProtectionHealthEvaluator]; the monitor only reacts to it.
 */
class HealthMonitorPolicy(
    private val renotifyAfterMs: Long = 6 * 60 * 60_000L,
) {
    private val backoffs = Repairable.entries.associateWith { Backoff() }
    private var notified: Pair<String, Long>? = null

    /** Detect + repair + notify in one call (repairs first, then status). */
    @Synchronized
    fun evaluate(o: MonitorObservation, now: Long): List<MonitorAction> =
        repairs(o, now).map { MonitorAction.Repair(it) } + notifications(o.report, o.protectionExpected, now)

    /** Components to repair now (respecting each one's backoff). */
    @Synchronized
    fun repairs(o: MonitorObservation, now: Long): List<Repairable> {
        if (!o.protectionExpected) return emptyList()
        return buildList {
            if (o.databaseFailing) add(Repairable.DATABASE)
            if (o.bundledListsMissing) add(Repairable.BUNDLED_LISTS)
            if (o.aiModelBroken) add(Repairable.AI_MODEL)
        }.filter { backoffs.getValue(it).canAttempt(now) }
    }

    /**
     * Notification changes for the (re-checked) report: one alert per
     * degradation reason, repeated at most every [renotifyAfterMs]; cleared
     * once when healthy again. Deliberate off states never alert.
     */
    @Synchronized
    fun notifications(report: HealthReport, protectionExpected: Boolean, now: Long): List<MonitorAction> {
        val degraded = protectionExpected && report.overall != OverallHealth.PROTECTED
        if (degraded) {
            val reason = report.reason ?: report.overall.name.lowercase()
            val last = notified
            if (last == null || last.first != reason || now - last.second >= renotifyAfterMs) {
                notified = reason to now
                return listOf(MonitorAction.Notify(report.overall, reason))
            }
            return emptyList()
        }
        if (notified != null) {
            notified = null
            return listOf(MonitorAction.ClearNotification)
        }
        return emptyList()
    }

    /** Report the outcome of a [MonitorAction.Repair]. */
    @Synchronized
    fun onRepairResult(c: Repairable, success: Boolean, now: Long) {
        val b = backoffs.getValue(c)
        b.onAttempt(now)
        if (success) b.onSuccess() else b.onFailure(now)
    }
}
