package com.safeguard.app.channel

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.AiStatistics
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.DetectionMode
import com.safeguard.app.engine.ai.ThresholdProfiles
import com.safeguard.app.engine.ai.image.ImageLimits
import com.safeguard.app.engine.ai.model.BuiltInModels
import com.safeguard.app.engine.apps.AppRuleException
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.health.HealthReport
import com.safeguard.app.engine.modes.ProtectionMode
import com.safeguard.app.engine.rules.UserRuleException
import com.safeguard.app.engine.search.CustomKeyword
import com.safeguard.app.engine.search.KeywordException
import com.safeguard.app.engine.stats.WindowStatistics
import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.safesearch.YouTubeMode
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.logging.LogRetention
import com.safeguard.app.engine.pause.TemporaryUnlock
import com.safeguard.app.engine.status.ProtectionStatus
import com.safeguard.app.protection.ProtectionManager
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
 *   getLogRetention() → "7d"|"30d"|"never"; setLogRetention({value}) → id
 *   monotonicTime() → {elapsedMs, boot}  (PIN lockout clock)
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
 * Phase 4 (AI, on-device):
 *   getAiSettings() / setAiSettings({enabled, mode, custom{category: v}})
 *     → {enabled, mode, custom, profiles{normal, strict}, models{text, image}}
 *   getAiStatistics() → {detections, blocks, falsePositiveReports,
 *     detectionsByCategory, blocksByCategory, reportsByCategory}
 *   reportFalsePositive({source, category, confidence}) → true
 *     (stores only those fields + time; never content)
 *   checkImage() → opens the system picker (no storage permission); the
 *     chosen image is read into memory, classified, and dropped →
 *     {status, error?, action, category, confidence, reason, scores, modelId}
 *     or {status: "cancelled"}
 *
 * Phase 5:
 *   setConfiguration also takes {mode: normal|strict|custom}
 *   addBlockedDomain category may be "custom"; addAllowedDomain takes
 *     {includeSubdomains}; errors DUPLICATE_DOMAIN, IN_OTHER_LIST
 *   getHealth() → {overall, reason, layers[{layer, state, reason}], mode,
 *     pausedRemainingMs, safeMode, incidents[{timestamp, kind}], lastBoot}
 *   acknowledgeIncidents({upTo}); tryRecover() → bool
 *   startPause({minutes: 5|10|30}) / endPause() → health
 *   enterSafeMode() → health
 *   getDetailedStatistics() → {today, last7Days, last30Days} each
 *     {total, bySource, byCategory, falsePositiveReports}
 *   getKeywords() / addKeyword({keyword, category}) / removeKeyword({id})
 *     errors INVALID_KEYWORD, KEYWORD_TOO_SHORT, DUPLICATE_KEYWORD, LIMIT_REACHED
 *   resetProtection() → health
 *   saveExport({json}) → system "save file" dialog; the JSON is built by
 *     Flutter from non-sensitive settings only → {status: saved|cancelled}
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
    private var pendingImage: MethodChannel.Result? = null
    private var pendingExport: Pair<MethodChannel.Result, String>? = null
    /**
     * Status changes come from several threads; posting the snapshot each
     * one saw could deliver them out of order. Instead every change posts a
     * read of the *current* status on the main thread, so the last event
     * Flutter receives is always the latest state.
     */
    private val statusListener: (ProtectionStatus) -> Unit = { _ -> main.post { sink?.success(manager.status.current.toMap()) } }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        manager.status.removeListener(statusListener)
        io.shutdown()
        // The activity is going away: don't leave Dart futures waiting forever.
        pendingPermission?.error("DETACHED", null, null)
        pendingImage?.error("DETACHED", null, null)
        pendingExport?.first?.error("DETACHED", null, null)
        pendingPermission = null
        pendingImage = null
        pendingExport = null
    }

    /** Forwarded from MainActivity.onActivityResult. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_IMAGE) {
            val result = pendingImage ?: return true
            pendingImage = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(mapOf("status" to "cancelled"))
            } else {
                io.execute { checkImage(uri, result) }
            }
            return true
        }
        if (requestCode == REQUEST_EXPORT) {
            val (result, json) = pendingExport ?: return true
            pendingExport = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(mapOf("status" to "cancelled"))
            } else {
                io.execute {
                    val value = try {
                        activity.contentResolver.openOutputStream(uri, "wt")?.use { it.write(json.toByteArray(Charsets.UTF_8)) }
                            ?: throw java.io.IOException("no stream")
                        mapOf("status" to "saved")
                    } catch (e: Exception) {
                        mapOf("status" to "failed")
                    }
                    main.post { result.success(value) }
                }
            }
            return true
        }
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
            main.post { this.sink?.success(manager.status.current.toMap()) }
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
            // The system list of battery exemptions: the user decides there.
            // (No REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission is used.)
            "openBatterySettings" -> result.success(open(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))
            "openPrivateDnsSettings" -> result.success(open(Intent(Settings.ACTION_WIRELESS_SETTINGS)))
            "checkImage" -> pickImage(result)
            "saveExport" -> saveExport(call, result)
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
                    val mode = call.argument<String>("mode")?.let { id ->
                        ProtectionMode.entries.firstOrNull { it.id == id } ?: throw bad("mode")
                    }
                    manager.setConfiguration(enabled, categories(call.argument<List<String>>("categories")), mode)
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
                    userCategory(call.argument("category")),
                ).toMap()
                "addAllowedDomain" -> manager.addUserRule(
                    domainArg(call),
                    RuleAction.ALLOW,
                    Category.SAFE,
                    includeSubdomains = call.argument<Boolean>("includeSubdomains") ?: false,
                ).toMap()
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
                "setUiLanguage" -> {
                    val value = call.argument<String>("language")
                    if (value != "ar" && value != "en") throw bad("language")
                    manager.config.uiLanguage = value
                    true
                }
                "getDiagnostics" -> manager.diagnostics()
                "getLogRetention" -> manager.config.logRetention.id
                "setLogRetention" -> {
                    val value = LogRetention.fromId(call.argument<String>("value")) ?: throw bad("value")
                    manager.setLogRetention(value)
                    value.id
                }
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
                "getAiSettings" -> aiSettings()
                "setAiSettings" -> {
                    val custom = (call.argument<Map<String, Any?>>("custom") ?: emptyMap())
                        .mapNotNull { (k, v) ->
                            val c = Category.fromId(k)?.takeIf { it.isFilterable } ?: return@mapNotNull null
                            (v as? Number)?.toDouble()?.let { c to it }
                        }.toMap()
                    manager.setAiSettings(
                        AiSettings(
                            enabled = call.argument<Boolean>("enabled") ?: throw bad("enabled"),
                            mode = DetectionMode.entries.firstOrNull { it.id == call.argument<String>("mode") } ?: throw bad("mode"),
                            customThresholds = custom,
                        ),
                    )
                    aiSettings()
                }
                "getAiStatistics" -> manager.aiStatistics().toMap()
                "reportFalsePositive" -> {
                    val source = EventSource.entries.firstOrNull { it.id == call.argument<String>("source") } ?: throw bad("source")
                    val confidence = call.argument<Number>("confidence")?.toDouble() ?: 0.0
                    manager.reportFalsePositive(source, category(call.argument("category")), confidence)
                    true
                }
                "getHealth" -> health()
                "acknowledgeIncidents" -> {
                    manager.config.acknowledgeIncidents(call.argument<Number>("upTo")?.toLong() ?: System.currentTimeMillis())
                    true
                }
                "tryRecover" -> manager.tryRecover()
                "monotonicTime" -> mapOf("elapsedMs" to SystemClock.elapsedRealtime(), "boot" to bootCount())
                "startPause" -> {
                    val minutes = call.argument<Int>("minutes") ?: throw bad("minutes")
                    if (minutes !in TemporaryUnlock.ALLOWED_MINUTES) throw bad("minutes")
                    manager.startPause(minutes)
                    health()
                }
                "endPause" -> { manager.endPause(); health() }
                "enterSafeMode" -> { manager.enterSafeMode(); health() }
                "resetProtection" -> { manager.resetProtection(); health() }
                "getDetailedStatistics" -> manager.detailedStatistics().let {
                    mapOf("today" to it.today.toMap(), "last7Days" to it.last7Days.toMap(), "last30Days" to it.last30Days.toMap())
                }
                "getKeywords" -> manager.keywords.list().map { it.toMap() }
                "addKeyword" -> manager.addKeyword(
                    call.argument<String>("keyword") ?: throw bad("keyword"),
                    userCategory(call.argument("category")),
                ).toMap()
                "removeKeyword" -> manager.removeKeyword(call.argument<Number>("id")?.toLong() ?: throw bad("id"))
                else -> {
                    main.post { result.notImplemented() }
                    return
                }
            }
            main.post { result.success(value) }
        } catch (e: ChannelError) {
            main.post { result.error(e.code, e.message, null) }
        } catch (e: UserRuleException) {
            main.post { result.error(e.error.code, e.error.code, null) }
        } catch (e: KeywordException) {
            main.post { result.error(e.error.code, e.error.code, null) }
        } catch (e: AppRuleException) {
            main.post { result.error(e.error.code, e.error.code, null) }
        } catch (e: IllegalArgumentException) {
            main.post { result.error("INVALID_ARGUMENT", null, null) }
        } catch (e: Exception) {
            // Class name only: messages may carry user input.
            main.post { result.error("INTERNAL", e.javaClass.simpleName, null) }
        }
    }

    /** Boot id for the PIN lockout; -1 where the platform doesn't expose it. */
    private fun bootCount(): Int = try {
        Settings.Global.getInt(activity.contentResolver, Settings.Global.BOOT_COUNT)
    } catch (e: Settings.SettingNotFoundException) {
        -1
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

    private fun health(): Map<String, Any?> {
        val report: HealthReport = manager.health()
        val c = manager.config
        return mapOf(
            "overall" to report.overall.name.lowercase(),
            "reason" to report.reason,
            "layers" to report.layers.map {
                mapOf("layer" to it.layer.id, "state" to it.state.name.lowercase(), "reason" to it.reason)
            },
            "mode" to c.mode.id,
            "pausedRemainingMs" to c.pauseRemainingMs(),
            "safeMode" to c.safeMode,
            "incidents" to c.incidents.unacknowledged().map { mapOf("timestamp" to it.timestamp, "kind" to it.kind.id) },
            "lastBoot" to c.lastBoot?.let { mapOf("result" to it.first, "at" to it.second) },
        )
    }

    /** Lets the user choose where to save; SafeGuard gets write access to that one file. */
    private fun saveExport(call: MethodCall, result: MethodChannel.Result) {
        val json = call.argument<String>("json")
        if (json == null || json.length > 1_000_000) {
            result.error("INVALID_ARGUMENT", "json", null)
            return
        }
        if (pendingExport != null) {
            result.error("BUSY", "Export already in progress", null)
            return
        }
        pendingExport = result to json
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("application/json")
            .putExtra(Intent.EXTRA_TITLE, "safeguard-settings.json")
        try {
            activity.startActivityForResult(intent, REQUEST_EXPORT)
        } catch (e: ActivityNotFoundException) {
            pendingExport = null
            result.error("UNSUPPORTED", "No document picker", null)
        }
    }

    private fun pickImage(result: MethodChannel.Result) {
        if (pendingImage != null) {
            result.error("BUSY", "Image picker already open", null)
            return
        }
        pendingImage = result
        // Storage Access Framework: the user picks one file; SafeGuard gets
        // read access to that file only, no storage permission.
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("image/*")
        try {
            activity.startActivityForResult(intent, REQUEST_IMAGE)
        } catch (e: ActivityNotFoundException) {
            pendingImage = null
            result.error("UNSUPPORTED", "No document picker", null)
        }
    }

    /** Reads at most the size limit into memory, classifies, and forgets the bytes. */
    private fun checkImage(uri: Uri, result: MethodChannel.Result) {
        val value: Map<String, Any?> = try {
            val limit = ImageLimits().maxBytes
            val mime = activity.contentResolver.getType(uri)
            val bytes = activity.contentResolver.openInputStream(uri)?.use { input ->
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    total += n
                    if (total > limit) return@use null
                    buffer.write(chunk, 0, n)
                }
                buffer.toByteArray()
            }
            if (bytes == null) {
                mapOf("status" to "rejected", "error" to "file_too_large")
            } else {
                val (r, d) = manager.checkImage(bytes, mime)
                bytes.fill(0)
                mapOf(
                    "status" to r.status.name.lowercase(),
                    "error" to r.error?.id,
                    "action" to d.action.name.lowercase(),
                    "category" to d.category.id,
                    "confidence" to d.confidence,
                    "reason" to d.reason,
                    "scores" to r.scores.mapKeys { it.key.id },
                    "modelId" to r.modelId,
                )
            }
        } catch (e: SecurityException) {
            mapOf("status" to "rejected", "error" to "unreadable")
        } catch (e: java.io.IOException) {
            mapOf("status" to "rejected", "error" to "unreadable")
        } catch (e: Exception) {
            mapOf("status" to "unavailable", "error" to "internal")
        }
        main.post { result.success(value) }
    }

    private fun aiSettings(): Map<String, Any?> = manager.config.rawAi.let { s ->
        mapOf(
            "enabled" to s.enabled,
            "mode" to s.mode.id,
            "custom" to s.customThresholds.mapKeys { it.key.id },
            "profiles" to mapOf(
                "normal" to ThresholdProfiles.NORMAL.mapKeys { it.key.id },
                "strict" to ThresholdProfiles.STRICT.mapKeys { it.key.id },
            ),
            "customRange" to listOf(ThresholdProfiles.MIN_CUSTOM, ThresholdProfiles.MAX_CUSTOM),
            "models" to mapOf(
                "text" to BuiltInModels.TEXT_V1.let {
                    mapOf("id" to it.id, "version" to it.version, "available" to manager.isAiAvailable(ContentKind.TEXT))
                },
                "image" to mapOf("id" to null, "version" to null, "available" to manager.isAiAvailable(ContentKind.IMAGE)),
            ),
        )
    }

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

    /** A category the user may give their own domains/keywords (incl. "custom"). */
    private fun userCategory(id: String?): Category {
        val c = Category.fromId(id) ?: throw bad("category")
        if (!c.isUserAssignable) throw bad("category")
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
        const val REQUEST_IMAGE = 0x5648
        const val REQUEST_EXPORT = 0x5649
    }
}

private fun AiStatistics.toMap(): Map<String, Any> = mapOf(
    "detections" to detections,
    "blocks" to blocks,
    "falsePositiveReports" to falsePositiveReports,
    "detectionsByCategory" to detectionsByCategory.mapKeys { it.key.id },
    "blocksByCategory" to blocksByCategory.mapKeys { it.key.id },
    "reportsByCategory" to reportsByCategory.mapKeys { it.key.id },
)

private fun WindowStatistics.toMap(): Map<String, Any> = mapOf(
    "total" to total,
    "bySource" to bySource.mapKeys { it.key.id },
    "byCategory" to byCategory.mapKeys { it.key.id },
    "falsePositiveReports" to falsePositiveReports,
)

private fun CustomKeyword.toMap(): Map<String, Any> =
    mapOf("id" to id, "keyword" to phrase, "category" to category.id, "addedAt" to addedAt)

private fun Rule.toMap(): Map<String, Any> = mapOf(
    "includeSubdomains" to includeSubdomains,
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
