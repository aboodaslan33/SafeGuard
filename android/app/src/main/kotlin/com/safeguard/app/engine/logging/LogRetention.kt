package com.safeguard.app.engine.logging

/**
 * How long the activity log (block events) is kept on the device.
 * [NEVER] means the log is never written: no per-event rows at all, so
 * statistics windows stay empty; only the lifetime block counter remains.
 */
enum class LogRetention(val id: String, val days: Int) {
    DAYS_7("7d", 7),
    DAYS_30("30d", 30),
    NEVER("never", 0);

    val keepsLog get() = days > 0
    val retentionMs get() = days * DAY_MS

    companion object {
        const val DAY_MS = 24L * 60 * 60 * 1000
        val DEFAULT = DAYS_30
        fun fromId(id: String?) = entries.firstOrNull { it.id == id }
    }
}
