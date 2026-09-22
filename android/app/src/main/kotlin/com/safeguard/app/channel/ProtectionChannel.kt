package com.safeguard.app.channel

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.safeguard.app.engine.apps.AppRuleException
import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.safesearch.YouTubeMode
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.status.ProtectionStatus
import com.safeguard.app.protection.ProtectionManager
import com.safeguard.app.protection.RuleValidationException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URLEncoder
import java.util.concurrent.Executors

/**
 * The only bridge between Flutter and the native protection stack.
 *
 * Method channel `com.safeguard.app/protection`:
 *   hasVpnPermission() → bool
 *   requestVpnPermission() → bool
 *   startProtection() → status | error PERMISSION_REQUIRED
 *   stopProtection() → status
 *   getProtectionStatus() → status
 *   setConfiguration({enabled, categories}) → status
 *   updateCategory({category, enabled}) → status
 *   addBlockedDomain({domain, category}) / addAllowedDomain({domain}) → rule
 *   removeBlockedDomain({domain}) / removeAllowedDomain({domain}) → bool
 *   getRules({action?, source?}) / searchRules({query}) → [rule]
 *   checkDomain({domain}) → decision
 *   getBlockedLogs({limit}) → [event]; clearLogs()
 *   getStatistics() → stats
 *   openVpnSettings(); eraseAll()
 *
 * Phase 3:
 *   getSearchSettings() / setSearchSettings({enabled, google, bing,
 *     duckDuckGo, youtube}) → settings
 *   submitSearch({query, engine}) → decision {action, category, confidence,
 *     ruleType, reason, opened}; opens results only if allowed. The query
 *     is never returned, stored or logged.
 *   getProtectedApps() / getLaunchableApps() → [{packageName, label, addedAt?}]
 *   addProtectedApp({packageName}) → app | error INVALID_PACKAGE,
 *     PACKAGE_NOT_INSTALLED, DUPLICATE_PACKAGE, PACKAGE_NOT_ALLOWED, LIMIT_REACHED
 *   removeProtectedApp({packageName}) → bool
 *   getAccessibilityStatus() / setAccessibilityDisclosure({accepted}) → {state}
 *   openAccessibilitySettings() → bool
 *
 * Event channel `com.safeguard.app/protection/status` streams status maps.
 *
 * Work runs on a background thread; results are delivered on the main
 * thread as Flutter requires.
 */
class ProtectionChannel(
    messenger: BinaryMessenger,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val manager = ProtectionManager.get(activity)
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { Thread(it, "sg-channel").apply { isDaemon = true } }
    private val methods = MethodChannel(messenger, METHOD_CHANNEL)
    private val events = EventChannel(messenger, EVENT_CHANNEL)
    private var sink: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val statusListener: (ProtectionStatus) -> Unit = { s -> main.post { sink?.success(s.toMap()) } }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        manager.status.removeListener(statusListener)
        io.shutdown()
    }

    /** Forwarded from MainActivity.onActivityResult. */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_VPN) return false
        val granted = resultCode == Activity.RESULT_OK
        pendingPermission?.success(granted)
        pendingPermission = null
        return true
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        this.sink = sink
        manager.status.addListener(statusListener)
        io.execute {
            manager.refreshEnvironment()
            val snapshot = manager.status.current.toMap()
            main.post { this.sink?.success(snapshot) }
        }
    }

    override fun onCancel(arguments: Any?) {
        manager.status.removeListener(statusListener)
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestVpnPermission" -> requestPermission(result)
            "openVpnSettings" -> result.success(open(Intent(Settings.ACTION_VPN_SETTINGS)))
            "openAccessibilitySettings" -> result.success(open(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)))
            else -> io.execute { handle(call, result) }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            val value: Any? = when (call.method) {
                "hasVpnPermission" -> manager.permissionIntent() == null
                "startProtection" -> {
                    if (!manager.start()) throw ChannelError("PERMISSION_REQUIRED", "VPN consent required")
                    status()
                }
                "stopProtection" -> { manager.stop(); status() }
                "getProtectionStatus" -> { manager.refreshEnvironment(); status() }
                "setConfiguration" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: throw bad("enabled")
                    manager.setConfiguration(enabled, categories(call.argument<List<String>>("categories")))
                    status()
                }
                "updateCategory" -> {
                    val category = category(call.argument("category"))
                    manager.setCategory(category, call.argument<Boolean>("enabled") ?: throw bad("enabled"))
                    status()
                }
                "addBlockedDomain" -> manager.addUserRule(
                    domainArg(call),
                    RuleAction.BLOCK,
                    category(call.argument("category")),
                ).toMap()
                "addAllowedDomain" -> manager.addUserRule(domainArg(call), RuleAction.ALLOW, Category.SAFE).toMap()
                "removeBlockedDomain" -> manager.removeUserRule(domainArg(call), RuleAction.BLOCK)
                "removeAllowedDomain" -> manager.removeUserRule(domainArg(call), RuleAction.ALLOW)
                "getRules" -> manager.rules.list(
                    source = call.argument<String>("source")?.let { RuleSource.fromId(it) ?: throw bad("source") },
                    action = call.argument<String>("action")?.let { action(it) },
                ).map { it.toMap() }
                "searchRules" -> {
                    val q = call.argument<String>("query")?.trim().orEmpty()
                    if (q.isEmpty() || q.length > 253) emptyList() else manager.rules.search(q).map { it.toMap() }
                }
                "checkDomain" -> manager.checkDomain(domainArg(call)).let {
                    mapOf(
                        "domain" to it.domain,
                        "action" to it.action.name.lowercase(),
                        "category" to it.category.id,
                        "reason" to it.reason.name.lowercase(),
                    )
                }
                "getBlockedLogs" -> manager.recentBlocks((call.argument<Int>("limit") ?: 100).coerceIn(1, 500)).map { it.toMap() }
                "clearLogs" -> { manager.clearLogs(); true }
                "getStatistics" -> manager.statistics().let { s ->
                    mapOf(
                        "today" to s.today,
                        "last7Days" to s.last7Days,
                        "total" to s.total,
                        "byCategory" to s.byCategory.mapKeys { it.key.id },
                    )
                }
                "eraseAll" -> { manager.eraseAll(); true }
                "getSearchSettings" -> searchSettings()
                "setSearchSettings" -> {
                    manager.setSearchConfig(
                        SafeSearchConfig(
                            enabled = call.argument<Boolean>("enabled") ?: throw bad("enabled"),
                            google = call.argument<Boolean>("google") ?: true,
                            bing = call.argument<Boolean>("bing") ?: true,
                            duckDuckGo = call.argument<Boolean>("duckDuckGo") ?: true,
                            youtube = YouTubeMode.entries.firstOrNull { it.id == call.argument<String>("youtube") }
                                ?: throw bad("youtube"),
                        ),
                    )
                    searchSettings()
                }
                "submitSearch" -> {
                    val query = call.argument<String>("query")?.trim().orEmpty()
                    val engine = call.argument<String>("engine") ?: "google"
                    if (query.isEmpty() || query.length > 512) throw bad("query")
                    val url = searchUrl(engine, query) ?: throw bad("engine")
                    val d = manager.submitSearch(query, engine)
                    val opened = d.action == RuleAction.ALLOW && open(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    mapOf(
                        "action" to d.action.name.lowercase(),
                        "category" to d.category.id,
                        "confidence" to d.confidence,
                        "ruleType" to d.ruleType,
                        "reason" to d.reason,
                        "opened" to opened,
                    )
                }
                "getProtectedApps" -> manager.protectedApps().map {
                    mapOf("packageName" to it.packageName, "label" to manager.appLabel(it.packageName), "addedAt" to it.addedAt)
                }
                "getLaunchableApps" -> manager.launchableApps().map { (label, pkg) ->
                    mapOf("packageName" to pkg, "label" to label)
                }
                "addProtectedApp" -> {
                    val app = manager.addProtectedApp(call.argument<String>("packageName") ?: throw bad("packageName"))
                    mapOf("packageName" to app.packageName, "label" to manager.appLabel(app.packageName), "addedAt" to app.addedAt)
                }
                "removeProtectedApp" -> manager.removeProtectedApp(call.argument<String>("packageName") ?: throw bad("packageName"))
                "getAccessibilityStatus" -> mapOf("state" to manager.accessibilityState().id)
                "setAccessibilityDisclosure" -> {
                    manager.config.accessibilityDisclosureDeclined = call.argument<Boolean>("accepted") != true
                    mapOf("state" to manager.accessibilityState().id)
                }
                else -> {
                    main.post { result.notImplemented() }
                    return
                }
            }
            main.post { result.success(value) }
        } catch (e: ChannelError) {
            main.post { result.error(e.code, e.message, null) }
        } catch (e: RuleValidationException) {
            main.post { result.error(e.code, e.message, null) }
        } catch (e: AppRuleException) {
            main.post { result.error(e.error.code, e.error.code, null) }
        } catch (e: Exception) {
            main.post { result.error("INTERNAL", e.javaClass.simpleName, null) }
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val intent = manager.permissionIntent()
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.error("BUSY", "Permission request already in progress", null)
            return
        }
        pendingPermission = result
        try {
            // The official system consent dialog. SafeGuard never tries to
            // bypass or pre-empt it.
            activity.startActivityForResult(intent, REQUEST_VPN)
        } catch (e: ActivityNotFoundException) {
            pendingPermission = null
            result.error("UNSUPPORTED", "This device does not support VPN apps", null)
        }
    }

    private fun status() = manager.status.current.toMap()

    private fun searchSettings() = manager.config.rawSafeSearch.let {
        mapOf(
            "enabled" to it.enabled,
            "google" to it.google,
            "bing" to it.bing,
            "duckDuckGo" to it.duckDuckGo,
            "youtube" to it.youtube.id,
        )
    }

    /** Results pages with each engine's own SafeSearch parameter as well. */
    private fun searchUrl(engine: String, query: String): String? {
        val q = URLEncoder.encode(query, "UTF-8")
        return when (engine) {
            "google" -> "https://www.google.com/search?safe=active&q=$q"
            "bing" -> "https://www.bing.com/search?adlt=strict&q=$q"
            "duckduckgo" -> "https://duckduckgo.com/?kp=1&q=$q"
            "youtube" -> "https://www.youtube.com/results?search_query=$q"
            else -> null
        }
    }

    private fun open(intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    private fun domainArg(call: MethodCall): String {
        val d = call.argument<String>("domain") ?: throw bad("domain")
        if (d.length > 2048) throw bad("domain")
        return d
    }

    private fun category(id: String?): Category {
        val c = Category.fromId(id) ?: throw bad("category")
        if (!c.isFilterable) throw bad("category")
        return c
    }

    private fun categories(ids: List<String>?): Set<Category> =
        (ids ?: throw bad("categories")).mapNotNull { Category.fromId(it) }.filter { it.isFilterable }.toSet()

    private fun action(name: String) =
        RuleAction.entries.firstOrNull { it.name.equals(name, ignoreCase = true) } ?: throw bad("action")

    private fun bad(arg: String) = ChannelError("INVALID_ARGUMENT", "Missing or invalid '$arg'")

    private class ChannelError(val code: String, message: String) : Exception(message)

    companion object {
        const val METHOD_CHANNEL = "com.safeguard.app/protection"
        const val EVENT_CHANNEL = "com.safeguard.app/protection/status"
        const val REQUEST_VPN = 0x5647
    }
}

private fun Rule.toMap(): Map<String, Any> = mapOf(
    "domain" to domain,
    "category" to category.id,
    "action" to action.name.lowercase(),
    "enabled" to enabled,
    "source" to source.id,
    "version" to version,
    "updatedAt" to updatedAt,
)

private fun BlockEvent.toMap(): Map<String, Any> = mapOf(
    "timestamp" to timestamp,
    "domain" to subject,
    "category" to category.id,
    "source" to source.id,
    "action" to action.name.lowercase(),
    "confidence" to confidence,
    "ruleType" to ruleType,
)
