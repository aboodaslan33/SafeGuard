package com.safeguard.app.engine.pause

/**
 * A timed pause of protection ("Temporary Unlock"). Filtering is off and
 * settings are editable without the PIN until it ends; it ends on its own.
 *
 * It is anchored to two clocks. The wall clock survives reboots but can be
 * changed by the user; elapsed-realtime can't be changed but resets on
 * reboot. The pause is active only while **both** agree, so moving the
 * clock back or rebooting can only end it early, never extend it.
 */
data class TemporaryUnlock(
    val startedAtWall: Long,
    val startedAtElapsed: Long,
    val durationMs: Long,
) {
    init {
        require(durationMs in 1..MAX_DURATION_MS) { "invalid duration" }
    }

    val endsAtWall: Long get() = startedAtWall + durationMs

    fun isActive(nowWall: Long, nowElapsed: Long): Boolean {
        val wallOk = nowWall >= startedAtWall && nowWall < endsAtWall
        val elapsedOk = nowElapsed >= startedAtElapsed && nowElapsed - startedAtElapsed < durationMs
        return wallOk && elapsedOk
    }

    /** Milliseconds left (0 when inactive), the smaller of both clocks. */
    fun remainingMs(nowWall: Long, nowElapsed: Long): Long {
        if (!isActive(nowWall, nowElapsed)) return 0
        return minOf(endsAtWall - nowWall, durationMs - (nowElapsed - startedAtElapsed))
    }

    companion object {
        val ALLOWED_MINUTES = listOf(5, 10, 30)
        const val MAX_DURATION_MS = 30L * 60 * 1000

        fun start(minutes: Int, nowWall: Long, nowElapsed: Long): TemporaryUnlock {
            require(minutes in ALLOWED_MINUTES) { "unsupported duration" }
            return TemporaryUnlock(nowWall, nowElapsed, minutes * 60_000L)
        }
    }
}
