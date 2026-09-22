package com.safeguard.app.engine.status

import java.util.concurrent.CopyOnWriteArrayList

enum class VpnState {
    STOPPED,
    STARTING,
    RUNNING,
    STOPPING,

    /** The user hasn't granted (or has withdrawn) VPN consent. */
    PERMISSION_REQUIRED,

    /** Another VPN took over or the user disconnected from system UI. */
    REVOKED,
    ERROR,
}

/** Everything the dashboard needs, as one immutable snapshot. */
data class ProtectionStatus(
    val vpnState: VpnState = VpnState.STOPPED,
    /** Packets are being read and DNS decisions made. */
    val dnsFilterActive: Boolean = false,
    /** Rules database loaded and engine ready. */
    val rulesReady: Boolean = false,
    val ruleCount: Int = 0,
    /** Rules that can actually block (list + user block rules). */
    val blockingRuleCount: Int = 0,
    val enabledCategories: Int = 0,
    val protectionEnabled: Boolean = false,
    /** A VPN from another app is active (only meaningful while ours isn't). */
    val otherVpnActive: Boolean = false,
    /** Android Private DNS in strict (hostname) mode: bypasses our DNS. */
    val privateDnsStrict: Boolean = false,
    /** An upstream DNS server is known (false when offline). */
    val upstreamAvailable: Boolean = false,
    val lastError: String? = null,
    val startedAt: Long? = null,
) {
    val isActive: Boolean
        get() = vpnState == VpnState.RUNNING && dnsFilterActive && rulesReady

    fun toMap(): Map<String, Any?> = mapOf(
        "vpnState" to vpnState.name.lowercase(),
        "dnsFilterActive" to dnsFilterActive,
        "rulesReady" to rulesReady,
        "ruleCount" to ruleCount,
        "blockingRuleCount" to blockingRuleCount,
        "enabledCategories" to enabledCategories,
        "protectionEnabled" to protectionEnabled,
        "otherVpnActive" to otherVpnActive,
        "privateDnsStrict" to privateDnsStrict,
        "upstreamAvailable" to upstreamAvailable,
        "lastError" to lastError,
        "startedAt" to startedAt,
        "active" to isActive,
    )
}

/**
 * Process-wide status holder. Updates are atomic; listeners are called on
 * the updating thread and must hand off to the UI thread themselves.
 */
class ProtectionStatusHolder(initial: ProtectionStatus = ProtectionStatus()) {
    @Volatile
    var current: ProtectionStatus = initial
        private set

    private val listeners = CopyOnWriteArrayList<(ProtectionStatus) -> Unit>()

    fun update(transform: (ProtectionStatus) -> ProtectionStatus) {
        val next: ProtectionStatus
        synchronized(this) {
            next = transform(current)
            if (next == current) return
            current = next
        }
        listeners.forEach { it(next) }
    }

    fun addListener(listener: (ProtectionStatus) -> Unit) = listeners.add(listener)
    fun removeListener(listener: (ProtectionStatus) -> Unit) = listeners.remove(listener)

    // Lifecycle transitions, kept here so they're unit-testable.

    fun starting() = update { it.copy(vpnState = VpnState.STARTING, lastError = null) }

    fun running(now: Long) = update {
        it.copy(vpnState = VpnState.RUNNING, dnsFilterActive = true, startedAt = now, lastError = null)
    }

    /**
     * Only a live (starting/running) VPN can be "stopping". The service calls
     * shutdown() again from onDestroy after revoke/stop/errors; that second
     * call must not overwrite the final state.
     */
    fun stopping() = update {
        if (it.vpnState == VpnState.RUNNING || it.vpnState == VpnState.STARTING) {
            it.copy(vpnState = VpnState.STOPPING)
        } else {
            it
        }
    }

    fun stopped() = update { it.down(VpnState.STOPPED) }

    fun revoked() = update { it.down(VpnState.REVOKED) }

    fun permissionRequired() = update { it.down(VpnState.PERMISSION_REQUIRED) }

    /** Network facts reported by the running VPN's network monitor. */
    fun upstreamChanged(available: Boolean, privateDnsStrict: Boolean) = update {
        it.copy(upstreamAvailable = available, privateDnsStrict = privateDnsStrict)
    }

    /** Facts that can be re-checked at any time (e.g. another VPN). */
    fun environmentChanged(otherVpnActive: Boolean) = update { it.copy(otherVpnActive = otherVpnActive) }

    fun failed(message: String) = update { it.down(VpnState.ERROR).copy(lastError = message) }

    /** A VPN that is no longer running has no filter and no upstream facts. */
    private fun ProtectionStatus.down(state: VpnState) = copy(
        vpnState = state,
        dnsFilterActive = false,
        startedAt = null,
        upstreamAvailable = false,
        privateDnsStrict = false,
    )
}
