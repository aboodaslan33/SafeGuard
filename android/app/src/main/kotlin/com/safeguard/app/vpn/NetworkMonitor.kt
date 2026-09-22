package com.safeguard.app.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import java.net.InetAddress

/** The physical network SafeGuard forwards allowed DNS queries through. */
data class UpstreamNetwork(
    val network: Network,
    val dnsServers: List<InetAddress>,
    /** Android Private DNS in strict mode (a hostname is configured). */
    val privateDnsStrict: Boolean,
)

/**
 * Tracks the default *non-VPN* network: Wi-Fi ↔ mobile data switches,
 * airplane mode, and its DNS servers.
 *
 * SafeGuard excludes its own package from the VPN, so the default network
 * *for this app* is always the underlying physical network.
 */
class NetworkMonitor(
    context: Context,
    private val onChange: (UpstreamNetwork?) -> Unit,
) {
    private val cm = context.getSystemService(ConnectivityManager::class.java)

    @Volatile
    var current: UpstreamNetwork? = null
        private set

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refresh(network)
        override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = refresh(network, lp)
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = refresh(network)
        override fun onLost(network: Network) {
            if (current?.network == network) publish(null)
        }
    }

    fun start() {
        try {
            cm.registerDefaultNetworkCallback(callback)
        } catch (e: RuntimeException) {
            // TooManyRequestsException etc.; fall back to a one-off read.
        }
        cm.activeNetwork?.let { refresh(it) }
    }

    fun stop() {
        try {
            cm.unregisterNetworkCallback(callback)
        } catch (e: IllegalArgumentException) {
            // Not registered.
        }
    }

    private fun refresh(network: Network, lp: LinkProperties? = null) {
        val caps = cm.getNetworkCapabilities(network) ?: return
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
        val props = lp ?: cm.getLinkProperties(network) ?: return
        val strict = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && props.privateDnsServerName != null
        publish(UpstreamNetwork(network, props.dnsServers.toList(), strict))
    }

    private fun publish(next: UpstreamNetwork?) {
        if (next == current) return
        current = next
        onChange(next)
    }

    companion object {
        /** True if a VPN that isn't ours is currently the default network. */
        fun otherVpnActive(context: Context, ourVpnRunning: Boolean): Boolean {
            if (ourVpnRunning) return false
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val caps = cm.activeNetwork?.let(cm::getNetworkCapabilities) ?: return false
            return caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    }
}
