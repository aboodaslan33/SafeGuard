package com.safeguard.app.engine.health

import com.safeguard.app.engine.apps.AccessibilityState
import com.safeguard.app.engine.status.VpnState

enum class OverallHealth { PROTECTED, PARTIALLY_PROTECTED, NOT_PROTECTED }

enum class LayerState {
    /** Working. */
    ACTIVE,

    /** Working with a problem that weakens protection. */
    DEGRADED,

    /** Should be working but isn't. */
    INACTIVE,

    /** Turned off by the user or the current mode (not a fault). */
    OFF,

    /** Nothing to do (e.g. no protected apps). */
    NOT_CONFIGURED,
}

enum class Layer(val id: String) {
    VPN("vpn"),
    DNS("dns"),
    RULES("rules"),
    SEARCH("search"),
    AI("ai"),
    APPS("apps"),
    DATABASE("database"),
    PERMISSIONS("permissions"),
}

/** [reason] is a stable id the UI translates (never free text). */
data class LayerHealth(val layer: Layer, val state: LayerState, val reason: String? = null)

data class HealthReport(val overall: OverallHealth, val layers: List<LayerHealth>, val reason: String? = null) {
    fun layer(l: Layer) = layers.first { it.layer == l }
}

/** Facts gathered by the Android layer; everything here is cheap to read. */
data class HealthInputs(
    val protectionEnabled: Boolean,
    val paused: Boolean = false,
    val safeMode: Boolean = false,
    val vpnState: VpnState,
    val vpnPermission: Boolean,
    val dnsFilterActive: Boolean,
    val upstreamAvailable: Boolean,
    val privateDnsStrict: Boolean = false,
    val otherVpnActive: Boolean = false,
    /** Allowed queries keep failing although a network is available. */
    val upstreamFailing: Boolean = false,
    val rulesReady: Boolean,
    val blockingRuleCount: Int,
    val customKeywordCount: Int = 0,
    val searchEnabled: Boolean,
    val aiEnabled: Boolean,
    val aiTextModelAvailable: Boolean,
    val protectedAppCount: Int,
    val accessibility: AccessibilityState,
    val databaseOk: Boolean,
)

/**
 * Turns facts into a per-layer report and one overall verdict:
 *
 * - NOT_PROTECTED: protection off, paused, Safe Mode, VPN not running, or
 *   the DNS filter not active — nothing is being filtered.
 * - PARTIALLY_PROTECTED: the DNS filter runs but a layer that should work
 *   is degraded or inactive (Private DNS bypass, failing upstream, no
 *   blocking rules, AI model missing, protected apps without the
 *   accessibility service, database errors).
 * - PROTECTED: everything that is switched on works.
 *
 * Layers the user switched off are OFF and don't lower the verdict.
 */
object ProtectionHealthEvaluator {

    fun evaluate(i: HealthInputs): HealthReport {
        val vpnRunning = i.vpnState == VpnState.RUNNING
        val vpn = when {
            !i.protectionEnabled -> LayerHealth(Layer.VPN, LayerState.OFF, "protection_off")
            i.safeMode -> LayerHealth(Layer.VPN, LayerState.OFF, "safe_mode")
            vpnRunning -> LayerHealth(Layer.VPN, LayerState.ACTIVE)
            i.vpnState == VpnState.STARTING -> LayerHealth(Layer.VPN, LayerState.INACTIVE, "starting")
            !i.vpnPermission || i.vpnState == VpnState.PERMISSION_REQUIRED ->
                LayerHealth(Layer.VPN, LayerState.INACTIVE, "permission_required")
            i.otherVpnActive || i.vpnState == VpnState.REVOKED -> LayerHealth(Layer.VPN, LayerState.INACTIVE, "other_vpn_or_revoked")
            i.vpnState == VpnState.ERROR -> LayerHealth(Layer.VPN, LayerState.INACTIVE, "vpn_error")
            else -> LayerHealth(Layer.VPN, LayerState.INACTIVE, "vpn_stopped")
        }
        val dns = when {
            vpn.state == LayerState.OFF -> LayerHealth(Layer.DNS, LayerState.OFF, vpn.reason)
            !vpnRunning || !i.dnsFilterActive -> LayerHealth(Layer.DNS, LayerState.INACTIVE, "filter_stopped")
            i.paused -> LayerHealth(Layer.DNS, LayerState.OFF, "paused")
            i.privateDnsStrict -> LayerHealth(Layer.DNS, LayerState.DEGRADED, "private_dns")
            i.upstreamFailing -> LayerHealth(Layer.DNS, LayerState.DEGRADED, "upstream_failing")
            !i.upstreamAvailable -> LayerHealth(Layer.DNS, LayerState.ACTIVE, "offline")
            else -> LayerHealth(Layer.DNS, LayerState.ACTIVE)
        }
        val rules = when {
            !i.rulesReady -> LayerHealth(Layer.RULES, LayerState.INACTIVE, "not_loaded")
            i.blockingRuleCount == 0 -> LayerHealth(Layer.RULES, LayerState.DEGRADED, "no_blocking_rules")
            else -> LayerHealth(Layer.RULES, LayerState.ACTIVE)
        }
        val search = when {
            !i.protectionEnabled || i.paused -> LayerHealth(Layer.SEARCH, LayerState.OFF, "protection_off")
            !i.searchEnabled -> LayerHealth(Layer.SEARCH, LayerState.OFF, "search_off")
            // SafeSearch is enforced through the VPN's DNS path.
            dns.state == LayerState.INACTIVE -> LayerHealth(Layer.SEARCH, LayerState.INACTIVE, "needs_vpn")
            else -> LayerHealth(Layer.SEARCH, LayerState.ACTIVE)
        }
        val ai = when {
            !i.protectionEnabled || i.paused -> LayerHealth(Layer.AI, LayerState.OFF, "protection_off")
            !i.aiEnabled -> LayerHealth(Layer.AI, LayerState.OFF, "ai_off")
            !i.aiTextModelAvailable -> LayerHealth(Layer.AI, LayerState.DEGRADED, "model_unavailable")
            else -> LayerHealth(Layer.AI, LayerState.ACTIVE)
        }
        val apps = when {
            i.protectedAppCount == 0 -> LayerHealth(Layer.APPS, LayerState.NOT_CONFIGURED)
            !i.protectionEnabled || i.paused -> LayerHealth(Layer.APPS, LayerState.OFF, "protection_off")
            i.accessibility == AccessibilityState.ENABLED -> LayerHealth(Layer.APPS, LayerState.ACTIVE)
            else -> LayerHealth(Layer.APPS, LayerState.INACTIVE, "accessibility_" + i.accessibility.id)
        }
        val db = if (i.databaseOk) LayerHealth(Layer.DATABASE, LayerState.ACTIVE) else LayerHealth(Layer.DATABASE, LayerState.DEGRADED, "database_error")
        val permissions = when {
            !i.vpnPermission -> LayerHealth(Layer.PERMISSIONS, LayerState.INACTIVE, "vpn_consent_missing")
            i.protectedAppCount > 0 && i.accessibility != AccessibilityState.ENABLED ->
                LayerHealth(Layer.PERMISSIONS, LayerState.DEGRADED, "accessibility_missing")
            else -> LayerHealth(Layer.PERMISSIONS, LayerState.ACTIVE)
        }
        val layers = listOf(vpn, dns, rules, search, ai, apps, db, permissions)

        val (overall, reason) = when {
            !i.protectionEnabled -> OverallHealth.NOT_PROTECTED to "protection_off"
            i.safeMode -> OverallHealth.NOT_PROTECTED to "safe_mode"
            i.paused -> OverallHealth.NOT_PROTECTED to "paused"
            vpn.state != LayerState.ACTIVE -> OverallHealth.NOT_PROTECTED to vpn.reason
            dns.state != LayerState.ACTIVE && dns.state != LayerState.DEGRADED -> OverallHealth.NOT_PROTECTED to dns.reason
            layers.any { it.state == LayerState.DEGRADED || it.state == LayerState.INACTIVE } ->
                OverallHealth.PARTIALLY_PROTECTED to layers.first { it.state == LayerState.DEGRADED || it.state == LayerState.INACTIVE }.let { it.layer.id + ":" + it.reason }
            else -> OverallHealth.PROTECTED to null
        }
        return HealthReport(overall, layers, reason)
    }
}
