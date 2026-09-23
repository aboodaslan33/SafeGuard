package com.safeguard.app.engine.health

import com.safeguard.app.engine.status.VpnState

/** Why protection stopped without the user asking. [id] is stored; never rename. */
enum class IncidentKind(val id: String) {
    /** Another VPN took over, or the VPN was disconnected in system settings. */
    VPN_REVOKED("vpn_revoked"),

    /** The filter crashed or failed to start, and recovery didn't bring it back. */
    VPN_FAILED("vpn_failed"),

    /** VPN consent was withdrawn. */
    PERMISSION_REVOKED("permission_revoked"),

    /** The accessibility service was switched off while apps are protected. */
    ACCESSIBILITY_DISABLED("accessibility_disabled"),

    /** After a reboot/update the system didn't let SafeGuard start. */
    BOOT_START_FAILED("boot_start_failed"),

    /** Recovery restarted the VPN after a failure (informational). */
    RECOVERED("recovered");

    companion object {
        fun fromId(id: String?) = entries.firstOrNull { it.id == id }
    }
}

data class Incident(val timestamp: Long, val kind: IncidentKind)

/**
 * Detects interruptions from status transitions. Only transitions the user
 * did not ask for count: stopping protection in SafeGuard (with the PIN),
 * a pause, or Safe Mode are not incidents.
 */
object IncidentDetector {
    fun onVpnTransition(previous: VpnState, next: VpnState, userWantsProtection: Boolean, now: Long): Incident? {
        if (!userWantsProtection || previous == next) return null
        val wasUp = previous == VpnState.RUNNING || previous == VpnState.STARTING
        return when (next) {
            VpnState.REVOKED -> if (wasUp) Incident(now, IncidentKind.VPN_REVOKED) else null
            VpnState.PERMISSION_REQUIRED -> Incident(now, IncidentKind.PERMISSION_REVOKED)
            VpnState.ERROR -> Incident(now, IncidentKind.VPN_FAILED)
            else -> null
        }
    }

    fun onAccessibilityChange(wasEnabled: Boolean, isEnabled: Boolean, protectedApps: Int, now: Long): Incident? =
        if (wasEnabled && !isEnabled && protectedApps > 0) Incident(now, IncidentKind.ACCESSIBILITY_DISABLED) else null
}

/** Bounded, append-only list of recent incidents (newest last). */
class IncidentLog(private val max: Int = 20) {
    private val items = ArrayDeque<Incident>()
    var acknowledgedUpTo: Long = 0
        private set

    @Synchronized fun add(i: Incident) {
        items.addLast(i)
        while (items.size > max) items.removeFirst()
    }

    @Synchronized fun all(): List<Incident> = items.toList()

    /** Incidents the user hasn't dismissed yet (RECOVERED is informational only). */
    @Synchronized fun unacknowledged(): List<Incident> =
        items.filter { it.timestamp > acknowledgedUpTo && it.kind != IncidentKind.RECOVERED }

    @Synchronized fun acknowledge(upTo: Long) {
        acknowledgedUpTo = maxOf(acknowledgedUpTo, upTo)
    }

    @Synchronized fun restore(list: List<Incident>, acknowledged: Long) {
        items.clear()
        list.takeLast(max).forEach { items.addLast(it) }
        acknowledgedUpTo = acknowledged
    }

    @Synchronized fun clear() {
        items.clear()
        acknowledgedUpTo = 0
    }
}

/**
 * When SafeGuard may try to bring the VPN back by itself, and how often.
 *
 * Never: when the user turned protection off, paused it, or chose Safe
 * Mode; when another VPN took over or the user disconnected in system
 * settings (REVOKED — SafeGuard never fights for the VPN slot); or when
 * consent is missing (only the user can grant it).
 *
 * Otherwise (ERROR, or STOPPED while it should run) at most [maxAttempts]
 * within [windowMs], waiting 1 s, 4 s, 16 s… between attempts.
 */
class RecoveryPolicy(
    private val maxAttempts: Int = 3,
    private val windowMs: Long = 10 * 60_000,
    private val baseDelayMs: Long = 1_000,
) {
    private val attempts = ArrayDeque<Long>()

    data class Facts(
        val userWantsProtection: Boolean,
        val paused: Boolean,
        val safeMode: Boolean,
        val vpnState: VpnState,
        val vpnPermission: Boolean,
        val otherVpnActive: Boolean,
    )

    fun isRecoverable(f: Facts): Boolean =
        f.userWantsProtection && !f.paused && !f.safeMode && f.vpnPermission && !f.otherVpnActive &&
            (f.vpnState == VpnState.ERROR || f.vpnState == VpnState.STOPPED)

    /** Delay before the next attempt, or null if recovery must not (or may no longer) be tried. */
    @Synchronized
    fun nextDelay(f: Facts, now: Long): Long? {
        if (!isRecoverable(f)) return null
        while (attempts.isNotEmpty() && now - attempts.first() >= windowMs) attempts.removeFirst()
        if (attempts.size >= maxAttempts) return null
        return baseDelayMs shl (2 * attempts.size) // 1 s, 4 s, 16 s
    }

    @Synchronized
    fun recordAttempt(now: Long) {
        attempts.addLast(now)
    }

    @Synchronized
    fun reset() = attempts.clear()
}

/**
 * Tracks whether allowed DNS queries reach the network's resolver. Offline
 * periods are not failures (nothing is sent). "Failing" = at least
 * [threshold] consecutive failures and no success for [windowMs]: the
 * signal for suggesting Safe Mode.
 */
class UpstreamHealth(private val threshold: Int = 5, private val windowMs: Long = 30_000) {
    private var consecutiveFailures = 0
    private var lastSuccess = 0L
    private var firstFailure = 0L

    @Synchronized fun success(now: Long) {
        consecutiveFailures = 0
        lastSuccess = now
    }

    @Synchronized fun failure(now: Long) {
        if (consecutiveFailures == 0) firstFailure = now
        consecutiveFailures++
    }

    @Synchronized fun isFailing(now: Long): Boolean =
        consecutiveFailures >= threshold && now - maxOf(lastSuccess, firstFailure) >= windowMs

    @Synchronized fun reset() {
        consecutiveFailures = 0
        lastSuccess = 0
        firstFailure = 0
    }
}
