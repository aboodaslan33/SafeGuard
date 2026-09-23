package com.safeguard.app.vpn

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Log
import com.safeguard.app.engine.dns.DnsPacketFilter
import com.safeguard.app.engine.status.VpnState
import com.safeguard.app.protection.ProtectionManager
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException

/**
 * Local-only VPN that sees DNS and nothing else.
 *
 * The tun interface gets one private address and routes exactly one
 * destination: a virtual DNS server (10.111.222.2) that Android hands to
 * every app as its resolver. All other traffic never enters the VPN — it
 * goes straight out through the normal network, untouched and unseen.
 *
 * Packets to the virtual DNS server are read here, decided by the rule
 * engine, and either answered with NXDOMAIN (blocked) or forwarded to the
 * network's own resolver (allowed). No traffic is sent to any SafeGuard
 * server; there isn't one.
 */
class SafeGuardVpnService : VpnService() {

    private val manager by lazy { ProtectionManager.get(this) }

    @Volatile private var tun: ParcelFileDescriptor? = null
    @Volatile private var worker: Thread? = null
    @Volatile private var interruptPipe: Array<FileDescriptor>? = null

    /** Set by shutdown(); distinguishes a requested stop from a crash. */
    @Volatile private var stopRequested = false
    private var forwarder: DnsForwarder? = null
    private var monitor: NetworkMonitor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_STOP -> {
                shutdown()
                manager.status.stopped()
                stopSelf()
                START_NOT_STICKY
            }
            else -> {
                // ACTION_START from the app, SERVICE_INTERFACE from Always-on
                // VPN, or a null intent when Android restarts a sticky service.
                if (!manager.config.enabled && intent?.action != ACTION_START) {
                    // The user turned protection off in SafeGuard; honour it
                    // even if the system tries to (re)start the VPN.
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (manager.config.safeMode) {
                    // Safe Mode: no automatic start (boot, Always-on, sticky
                    // restart) until the user re-enables protection in the app.
                    stopSelf()
                    return START_NOT_STICKY
                }
                establish()
                START_STICKY
            }
        }
    }

    @Synchronized
    private fun establish() {
        if (tun != null) return
        if (prepare(this) != null) {
            manager.status.permissionRequired()
            stopSelf()
            return
        }
        stopRequested = false
        manager.status.starting()
        try {
            val monitor = NetworkMonitor(this) { net -> onNetworkChanged(net) }.also { it.start() }
            this.monitor = monitor

            val builder = Builder()
                .setSession("SafeGuard")
                .addAddress(TUN_ADDRESS, 32)
                .addDnsServer(VIRTUAL_DNS)
                .addRoute(VIRTUAL_DNS, 32)
                .setMtu(MTU)
                .setBlocking(true)
                .setConfigureIntent(manager.launchIntent())
            try {
                // Our own sockets (and UI) use the physical network directly.
                builder.addDisallowedApplication(packageName)
            } catch (e: PackageManager.NameNotFoundException) {
                Log.w(TAG, "could not exclude own package", e)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Metered-ness follows the underlying network, not "VPN = metered".
                builder.setMetered(false)
            }
            monitor.current?.let { builder.setUnderlyingNetworks(arrayOf(it.network)) }

            val fd = builder.establish()
            if (fd == null) {
                // Consent was revoked between prepare() and establish().
                manager.status.permissionRequired()
                shutdown()
                stopSelf()
                return
            }
            tun = fd
            val forwarder = DnsForwarder(this, { this.monitor?.current }, manager.upstreamHealth)
            this.forwarder = forwarder
            interruptPipe = Os.pipe()
            worker = Thread({ runLoop(fd, forwarder) }, "sg-vpn-loop").apply { start() }
            manager.status.running(System.currentTimeMillis())
            manager.onUpstreamChanged(monitor.current)
        } catch (e: Exception) {
            Log.e(TAG, "failed to start VPN", e)
            manager.status.failed(e.javaClass.simpleName + ": " + (e.message ?: ""))
            shutdown()
            stopSelf()
        }
    }

    private fun onNetworkChanged(net: UpstreamNetwork?) {
        // Wi-Fi ↔ mobile data, airplane mode: keep the tun up, just move the
        // upstream. While offline, allowed queries get SERVFAIL immediately
        // and blocked ones are still blocked (rules are local).
        if (tun != null) {
            setUnderlyingNetworks(net?.let { arrayOf(it.network) })
        }
        if (tun != null) manager.onUpstreamChanged(net)
    }

    private fun runLoop(fd: ParcelFileDescriptor, forwarder: DnsForwarder) {
        val input = FileInputStream(fd.fileDescriptor)
        val output = FileOutputStream(fd.fileDescriptor)
        val writeLock = Any()
        val write: (ByteArray) -> Unit = { packet ->
            synchronized(writeLock) {
                try {
                    output.write(packet)
                } catch (e: IOException) {
                    // Interface closed while an answer was in flight.
                }
            }
        }
        val filter = DnsPacketFilter(
            manager.engine,
            { manager.config.policy },
            manager.logger,
            safeSearch = { manager.config.safeSearch },
        )
        val buffer = ByteArray(MTU)
        val pipe = interruptPipe ?: return
        val pollTun = StructPollfd().apply { this.fd = fd.fileDescriptor; events = OsConstants.POLLIN.toShort() }
        val pollStop = StructPollfd().apply { this.fd = pipe[0]; events = OsConstants.POLLIN.toShort() }

        var failure: String? = null
        try {
            while (!Thread.currentThread().isInterrupted) {
                // Blocks without spinning (no battery drain while idle) until
                // a packet arrives or shutdown() writes to the pipe.
                pollTun.revents = 0
                pollStop.revents = 0
                Os.poll(arrayOf(pollTun, pollStop), -1)
                if (pollStop.revents.toInt() != 0) break
                val events = pollTun.revents.toInt()
                if (events and (OsConstants.POLLERR or OsConstants.POLLHUP or OsConstants.POLLNVAL) != 0) {
                    // The interface is gone. Without this check poll() would
                    // return immediately forever: a 100% CPU spin.
                    failure = "VPN interface closed"
                    break
                }
                if (events and OsConstants.POLLIN == 0) continue
                val length = input.read(buffer)
                if (length <= 0) continue
                when (val outcome = filter.process(buffer, length)) {
                    is DnsPacketFilter.Outcome.Reply -> write(outcome.packet)
                    is DnsPacketFilter.Outcome.Forward -> forwarder.forward(outcome.request, write)
                    DnsPacketFilter.Outcome.Drop -> Unit
                }
            }
        } catch (e: ErrnoException) {
            Log.w(TAG, "poll failed", e)
            failure = "poll: ${e.errno}"
        } catch (e: IOException) {
            Log.w(TAG, "tun read failed", e)
            failure = "tun read: ${e.javaClass.simpleName}"
        } catch (e: RuntimeException) {
            Log.e(TAG, "filter loop crashed", e)
            failure = "filter loop: ${e.javaClass.simpleName}"
        }
        if (!stopRequested) {
            // The loop died on its own. Leaving the tun up would route every
            // DNS query into a dead interface (the device loses name
            // resolution while the UI says "active"): tear down, then try a
            // bounded, backed-off recovery (RecoveryPolicy). If recovery is
            // not allowed or exhausted, report the failure honestly.
            val reason = failure ?: "filter loop stopped"
            val main = Handler(Looper.getMainLooper())
            main.post {
                shutdown()
                val delay = manager.recovery.nextDelay(manager.recoveryFacts(VpnState.ERROR), System.currentTimeMillis())
                if (delay == null) {
                    manager.status.failed(reason)
                    stopSelf()
                    return@post
                }
                manager.status.starting()
                main.postDelayed({
                    manager.recovery.recordAttempt(System.currentTimeMillis())
                    if (!manager.config.enabled || manager.config.safeMode) {
                        manager.status.stopped()
                        stopSelf()
                        return@postDelayed
                    }
                    establish()
                    if (tun != null) manager.onRecovered()
                }, delay)
            }
        }
    }

    @Synchronized
    private fun shutdown() {
        stopRequested = true
        manager.status.stopping()
        interruptPipe?.let { pipe ->
            try {
                Os.write(pipe[1], byteArrayOf(1), 0, 1)
            } catch (e: Exception) {
                // Pipe already closed.
            }
        }
        worker?.let {
            it.interrupt()
            try {
                it.join(1000)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        worker = null
        forwarder?.shutdown()
        forwarder = null
        monitor?.stop()
        monitor = null
        try {
            tun?.close()
        } catch (e: IOException) {
            // Ignore.
        }
        tun = null
        interruptPipe?.forEach {
            try {
                Os.close(it)
            } catch (e: ErrnoException) {
                // Ignore.
            }
        }
        interruptPipe = null
    }

    /** Another VPN was activated, or the user disconnected us in Settings. */
    override fun onRevoke() {
        shutdown()
        manager.status.revoked()
        manager.refreshEnvironment()
        super.onRevoke() // stops the service
    }

    override fun onDestroy() {
        val wasRunning = tun != null
        shutdown()
        if (wasRunning) manager.status.stopped()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "SafeGuardVpn"
        const val ACTION_START = "com.safeguard.app.vpn.START"
        const val ACTION_STOP = "com.safeguard.app.vpn.STOP"
        const val MTU = 1500
        private const val TUN_ADDRESS = "10.111.222.1"
        const val VIRTUAL_DNS = "10.111.222.2"

        fun start(context: Context) {
            val intent = Intent(context, SafeGuardVpnService::class.java).setAction(ACTION_START)
            context.startService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, SafeGuardVpnService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
