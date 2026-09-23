package com.safeguard.app.protection

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.telecom.TelecomManager
import android.util.Log
import android.view.accessibility.AccessibilityManager
import com.safeguard.app.MainActivity
import com.safeguard.app.ai.BitmapImageDecoder
import com.safeguard.app.ai.LiteRtImageRuntime
import com.safeguard.app.apps.AppGuardService
import com.safeguard.app.data.SafeGuardDatabase
import com.safeguard.app.data.SqliteAiStatsStore
import com.safeguard.app.data.SqliteBlockEventStore
import com.safeguard.app.data.SqliteCustomKeywordStore
import com.safeguard.app.data.SqliteProtectedAppStore
import com.safeguard.app.data.SqliteRuleStore
import com.safeguard.app.engine.ai.AdapterContentClassifier
import com.safeguard.app.engine.ai.AiSearchFilterService
import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.AiStatsRecorder
import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.DecisionPolicy
import com.safeguard.app.engine.ai.FalsePositiveReport
import com.safeguard.app.engine.ai.GuardedContentClassifier
import com.safeguard.app.engine.ai.InferenceBudget
import com.safeguard.app.engine.ai.ProtectionDecision
import com.safeguard.app.engine.ai.ProtectionDecisionEngine
import com.safeguard.app.engine.ai.RuleSignal
import com.safeguard.app.engine.ai.image.ImageRejectedException
import com.safeguard.app.engine.ai.image.LocalImageClassifierAdapter
import com.safeguard.app.engine.ai.model.BuiltInModels
import com.safeguard.app.engine.ai.model.ModelLoader
import com.safeguard.app.engine.ai.text.LocalTextClassifierAdapter
import com.safeguard.app.engine.ai.text.TextModel
import com.safeguard.app.engine.apps.AccessibilityState
import com.safeguard.app.engine.apps.AccessibilityStateResolver
import com.safeguard.app.engine.apps.AppAction
import com.safeguard.app.engine.apps.AppDecision
import com.safeguard.app.engine.apps.AppProtection
import com.safeguard.app.engine.apps.ProtectedApp
import com.safeguard.app.engine.backup.KeywordEntry
import com.safeguard.app.engine.backup.UserConfig
import com.safeguard.app.engine.backup.UserConfigBackup
import com.safeguard.app.engine.backup.UserRuleEntry
import com.safeguard.app.engine.domain.DomainName
import com.safeguard.app.engine.explain.DecisionTrace
import com.safeguard.app.engine.health.HealthInputs
import com.safeguard.app.engine.health.HealthMonitorPolicy
import com.safeguard.app.engine.health.HealthReport
import com.safeguard.app.engine.health.Incident
import com.safeguard.app.engine.health.IncidentDetector
import com.safeguard.app.engine.health.IncidentKind
import com.safeguard.app.engine.health.MonitorAction
import com.safeguard.app.engine.health.MonitorObservation
import com.safeguard.app.engine.health.OverallHealth
import com.safeguard.app.engine.health.ProtectionHealthEvaluator
import com.safeguard.app.engine.health.RecoveryPolicy
import com.safeguard.app.engine.health.Repairable
import com.safeguard.app.engine.health.UpstreamHealth
import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.logging.LogRetention
import com.safeguard.app.engine.modes.ProtectionMode
import com.safeguard.app.engine.pause.TemporaryUnlock
import com.safeguard.app.engine.privacy.QueryHasher
import com.safeguard.app.engine.privacy.SearchEventRecorder
import com.safeguard.app.engine.rules.BuiltInRules
import com.safeguard.app.engine.rules.BundledListStore
import com.safeguard.app.engine.rules.BundledLists
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.CompositeRuleStore
import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.HashedDomainList
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.rules.UserRules
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.search.CustomKeywords
import com.safeguard.app.engine.search.RuleBasedSearchClassifier
import com.safeguard.app.engine.search.SearchDecision
import com.safeguard.app.engine.search.SearchDecisionListener
import com.safeguard.app.engine.search.SearchFilterService
import com.safeguard.app.engine.search.SearchNormalizer
import com.safeguard.app.engine.search.SearchQuery
import com.safeguard.app.engine.shield.BlockAction
import com.safeguard.app.engine.shield.BuiltInImagePacks
import com.safeguard.app.engine.shield.ContentShieldEngine
import com.safeguard.app.engine.shield.ImageModelPack
import com.safeguard.app.engine.shield.ImageModelState
import com.safeguard.app.engine.shield.ImageRuntimeKind
import com.safeguard.app.engine.shield.PackImageModelRuntime
import com.safeguard.app.engine.shield.ShieldEvent
import com.safeguard.app.engine.shield.ShieldImageClassifier
import com.safeguard.app.engine.shield.ShieldStatus
import com.safeguard.app.engine.shield.ShieldStatusResolver
import com.safeguard.app.engine.shield.SupportedApps
import com.safeguard.app.engine.stats.BlockStatistics
import com.safeguard.app.engine.stats.DetailedStatistics
import com.safeguard.app.engine.stats.StatisticsService
import com.safeguard.app.engine.status.ProtectionStatusHolder
import com.safeguard.app.engine.status.VpnState
import com.safeguard.app.shield.ContentShieldService
import com.safeguard.app.shield.ScreenCaptureService
import com.safeguard.app.vpn.NetworkMonitor
import com.safeguard.app.vpn.SafeGuardVpnService
import com.safeguard.app.vpn.UpstreamNetwork
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Process-wide facade over the native protection stack. Both the VPN
 * service and the Flutter channel talk to this object only.
 */
class ProtectionManager private constructor(private val context: Context) {

    val config = ProtectionConfigStore(context)
    private val database = SafeGuardDatabase(context)
    val rules = SqliteRuleStore(database)
    @Volatile private var bundledLists: List<HashedDomainList> = emptyList()

    /** SQLite rules + the bundled category lists (loaded in the background). */
    val engine = RuleEngine(CompositeRuleStore(rules, BundledListStore { bundledLists }, ::onDatabaseFailure))

    /** Last time a rule lookup hit a database error (0 = never). */
    @Volatile private var lastDatabaseFailureAt = 0L

    /** Set once the bundled lists finished loading (or failed to). */
    @Volatile private var listsLoaded = false

    private fun onDatabaseFailure(e: RuntimeException) {
        val now = System.currentTimeMillis()
        if (now - lastDatabaseFailureAt > 60_000) Log.w("SafeGuard", "rule lookup failed: ${e.javaClass.simpleName}")
        lastDatabaseFailureAt = now
    }

    /** The database opened and no lookup failed in the last 5 minutes. */
    private fun databaseOk(): Boolean =
        database.isHealthy() && System.currentTimeMillis() - lastDatabaseFailureAt > 5 * 60_000
    private val events = SqliteBlockEventStore(database)
    private val logExecutor = Executors.newSingleThreadExecutor { Thread(it, "sg-block-log").apply { isDaemon = true } }
    val logger = BlockLogger(events, logExecutor, retention = { config.logRetention })
    private val statistics by lazy { StatisticsService(events, reportsSince = aiStats::reportsSince) }
    val status = ProtectionStatusHolder()

    // Live counters: every stored event bumps status.activityVersion, at most
    // twice a second (a burst of blocks becomes one update).
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    @Volatile private var activityPending = false
    private val activityPulse = Runnable {
        activityPending = false
        status.activityChanged()
    }

    private fun onActivity() {
        if (activityPending) return
        activityPending = true
        mainHandler.postDelayed(activityPulse, 500)
    }

    /** Non-exportable Keystore HMAC key (event ids, AI cache keys). */
    private val hmacKey = KeystoreHmacKey(context)
    private val hasher = QueryHasher(hmacKey)

    // ---- AI (Phase 4): on-device only, on demand only -------------------

    private val aiStats = SqliteAiStatsStore(database)
    private val aiStatsRecorder = AiStatsRecorder(aiStats)

    /**
     * Local adapters only. The text model loads lazily from APK assets after
     * its size and SHA-256 are verified. "Check an image" uses the same
     * pinned image model as the Content Shield ([PackImageModelRuntime]),
     * opened per check after its SHA-256 is verified. No cloud adapter is
     * registered.
     */
    private val checkImageRuntime: PackImageModelRuntime? = BuiltInImagePacks.all.firstOrNull()?.let { pack ->
        PackImageModelRuntime(pack) {
            val model = mapAsset(pack)
            if (model == null || model.capacity().toLong() != pack.sizeBytes || !ShieldImageClassifier.sha256Matches(model, pack.sha256)) {
                null
            } else {
                LiteRtImageRuntime.factory.open(pack, model)
            }
        }
    }
    private val imageAdapter = LocalImageClassifierAdapter("local-image", BitmapImageDecoder(), { checkImageRuntime })

    private val textAdapter = LocalTextClassifierAdapter(BuiltInModels.TEXT_V1.id, {
        TextModel.parse(ModelLoader { path -> context.assets.open(path) }.load(BuiltInModels.TEXT_V1))
    })

    val contentClassifier = GuardedContentClassifier(
        AdapterContentClassifier(
            listOf(
                textAdapter,
                imageAdapter,
            ),
        ),
        macs = hmacKey,
    )

    val keywords = CustomKeywords(SqliteCustomKeywordStore(database))

    // ---- AI Content Shield (final AI phase) -------------------------------

    /**
     * Text classification for the shield: the same verified on-device text
     * model, behind its own cache and a separate budget so screen text can
     * never starve search filtering (over budget → UNKNOWN, not BLOCK).
     */
    private val shieldText = GuardedContentClassifier(
        AdapterContentClassifier(listOf(textAdapter)),
        macs = hmacKey,
        budget = InferenceBudget(mapOf(ContentKind.TEXT to 60, ContentKind.IMAGE to 0)),
        capacity = 64,
    )

    /**
     * Screen-image classification with the pinned image model pack, run by
     * LiteRT. The model file is memory-mapped from the APK (stored
     * uncompressed), SHA-256-checked, loaded on the first frame and released
     * when capture, the shield or protection stops.
     */
    private val shieldImage = ShieldImageClassifier(
        BuiltInImagePacks.all.firstOrNull(),
        readModel = ::mapAsset,
        runtimes = { kind -> if (kind == ImageRuntimeKind.TFLITE) LiteRtImageRuntime.factory else null },
    )

    /** App in front, as last reported by the shield's accessibility service (supported apps only). */
    @Volatile var shieldForeground: String? = null

    val shield = ContentShieldEngine(
        classifyText = shieldText::classifyText,
        image = shieldImage,
        policy = { DecisionPolicy(config.filteringActive, config.effectiveCategories, config.effectiveAi) },
        settings = { config.shieldSettings },
        protectionActive = { config.filteringActive },
        // Launcher, dialer, system UI, settings and SafeGuard itself are never inspected.
        isExempt = { pkg -> appProtection.isNeverProtectable(pkg) },
    )

    /** Content-free debug trace of recent decisions (off by default, memory only). */
    val trace = DecisionTrace()
    private val searchRecorder by lazy { SearchEventRecorder(logger, hasher) }

    private val userRules = UserRules(rules)

    // ---- Health, recovery, interruptions (Phase 5) ----------------------

    val recovery = RecoveryPolicy()
    val upstreamHealth = UpstreamHealth()

    /** Search filtering: custom keywords, rule layer, then the on-device text model. */
    val searchFilter: SearchFilterService = AiSearchFilterService(
        rules = RuleBasedSearchClassifier(),
        config = { config.searchPolicy },
        ai = contentClassifier,
        aiSettings = { config.effectiveAi },
        listener = SearchDecisionListener { q, d ->
            searchRecorder.onDecision(q, d)
            trace.recordSearch(d, System.currentTimeMillis())
        },
        aiListener = aiStatsRecorder,
        keywords = keywords,
    )

    /**
     * Search filtering for queries typed into the search boxes of apps the
     * AI Content Shield covers. Same layers and logging as web searches
     * (only a keyed hash of a blocked query is kept).
     */
    private val appSearchFilter: SearchFilterService = AiSearchFilterService(
        rules = RuleBasedSearchClassifier(),
        config = { config.appSearchPolicy },
        ai = contentClassifier,
        aiSettings = { config.effectiveAi },
        listener = SearchDecisionListener { q, d ->
            searchRecorder.onDecision(q, d)
            trace.recordSearch(d, System.currentTimeMillis())
        },
        aiListener = aiStatsRecorder,
        keywords = keywords,
    )

    private val protectedApps = SqliteProtectedAppStore(database)
    val appProtection = AppProtection(
        store = protectedApps,
        isInstalled = { pkg -> context.packageManager.getLaunchIntentForPackage(pkg) != null },
        neverProtect = ::deviceExemptPackages,
    )

    private val isDebuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    init {
        logger.onRecorded = ::onActivity
        logger.applyRetention()
        seedBuiltInRules()
        if (database.createdFresh) restoreUserConfig()
        refreshRuleCounts()
        // ~10 MB of lists: map and verify off the main thread, then enable.
        Thread({
            bundledLists = loadBundledLists()
            listsLoaded = true
            engine.invalidate()
            refreshRuleCounts()
        }, "sg-lists").apply { isDaemon = true }.start()
        status.update { it.copy(protectionEnabled = config.enabled, enabledCategories = config.effectiveCategories.size) }
        // Interruption ("tamper") detection: VPN transitions the user didn't ask for.
        // Listeners run on whichever thread changed the status: serialise.
        var previous = status.current.vpnState
        val incidentLock = Any()
        status.addListener { s ->
            synchronized(incidentLock) {
                if (s.vpnState == previous) return@synchronized
                val incident = IncidentDetector.onVpnTransition(
                    previous,
                    s.vpnState,
                    userWantsProtection = config.enabled && !config.safeMode,
                    now = System.currentTimeMillis(),
                )
                previous = s.vpnState
                if (incident != null) config.addIncident(incident)
            }
        }
    }

    // ---- VPN lifecycle -------------------------------------------------

    /** Intent to show the system VPN consent dialog, or null if granted. */
    fun permissionIntent(): Intent? = VpnService.prepare(context)

    /** Starts the VPN (and leaves Safe Mode). Returns false if consent is required first. */
    fun start(): Boolean {
        config.update(enabled = true)
        config.safeMode = false
        recovery.reset()
        upstreamHealth.reset()
        status.update { it.copy(protectionEnabled = true) }
        if (permissionIntent() != null) {
            status.permissionRequired()
            return false
        }
        SafeGuardVpnService.start(context)
        onShieldStateChanged()
        return true
    }

    fun stop() {
        config.update(enabled = false)
        status.update { it.copy(protectionEnabled = false) }
        SafeGuardVpnService.stop(context)
        onShieldStateChanged()
    }

    /** Re-checks conditions outside our control (another VPN). Safe to call anytime. */
    fun refreshEnvironment() {
        val running = status.current.vpnState == VpnState.RUNNING
        status.environmentChanged(NetworkMonitor.otherVpnActive(context, running))
    }

    /** Called by the VPN service whenever its physical network changes. */
    fun onUpstreamChanged(upstream: UpstreamNetwork?) {
        status.upstreamChanged(
            available = upstream != null,
            privateDnsStrict = upstream?.privateDnsStrict ?: false,
        )
        refreshEnvironment()
    }

    // ---- Configuration -------------------------------------------------

    fun setConfiguration(enabled: Boolean, categories: Set<Category>, mode: ProtectionMode? = null) {
        val policy = config.update(enabled = enabled, categories = categories, mode = mode)
        status.update { it.copy(protectionEnabled = policy.enabled, enabledCategories = config.effectiveCategories.size) }
        onShieldStateChanged()
    }

    fun setCategory(category: Category, enabled: Boolean) {
        require(category.isFilterable) { "not a filterable category" }
        config.setCategory(category, enabled)
        status.update { it.copy(enabledCategories = config.effectiveCategories.size) }
    }

    // ---- Temporary unlock, Safe Mode (Phase 5) --------------------------

    /**
     * Pauses filtering for [minutes] (5/10/30; the PIN was checked in the
     * UI). The VPN stays up; the filter reads the deadline on every query,
     * so protection resumes on time even if SafeGuard's UI is closed.
     */
    fun startPause(minutes: Int): TemporaryUnlock {
        val p = config.startPause(minutes)
        logger.record(
            BlockEvent(
                timestamp = p.startedAtWall,
                subject = "unlock:${minutes}m",
                category = Category.UNKNOWN,
                source = EventSource.MANUAL,
                action = RuleAction.ALLOW,
                ruleType = BlockEvent.RULE_TYPE_TEMPORARY_UNLOCK,
            ),
        )
        onShieldStateChanged()
        return p
    }

    fun endPause() {
        config.endPause()
        onShieldStateChanged()
    }

    /**
     * Safe Mode: stops the VPN so a filtering problem can't keep the device
     * offline, and blocks automatic restarts until [start] is called.
     */
    fun enterSafeMode() {
        config.safeMode = true
        SafeGuardVpnService.stop(context)
        onShieldStateChanged()
    }

    fun recordIncident(kind: IncidentKind) = config.addIncident(Incident(System.currentTimeMillis(), kind))

    /** Called by the VPN service when a recovery attempt brought the filter back. */
    fun onRecovered() = recordIncident(IncidentKind.RECOVERED)

    fun recoveryFacts(state: VpnState = status.current.vpnState) = RecoveryPolicy.Facts(
        userWantsProtection = config.enabled,
        paused = config.isPaused(),
        safeMode = config.safeMode,
        vpnState = state,
        vpnPermission = permissionIntent() == null,
        otherVpnActive = status.current.otherVpnActive,
    )

    /**
     * App-side recovery (e.g. when SafeGuard comes to the foreground): if
     * protection should run but the VPN is stopped or failed, and the
     * policy allows it, request one restart. Returns true if attempted; the
     * result is visible in the next status/health report.
     */
    fun tryRecover(): Boolean {
        refreshEnvironment()
        val now = System.currentTimeMillis()
        recovery.nextDelay(recoveryFacts(), now) ?: return false
        recovery.recordAttempt(now)
        SafeGuardVpnService.start(context)
        return true
    }

    fun health(): HealthReport {
        refreshEnvironment()
        val a11y = accessibilityState()
        val appCount = runCatching { protectedApps.list().size }.getOrDefault(0)
        val a11yOn = a11y == AccessibilityState.ENABLED
        IncidentDetector.onAccessibilityChange(config.accessibilityWasEnabled, a11yOn, appCount, System.currentTimeMillis())
            ?.let { config.addIncident(it) }
        if (config.accessibilityWasEnabled != a11yOn) config.accessibilityWasEnabled = a11yOn
        val s = status.current
        return ProtectionHealthEvaluator.evaluate(
            HealthInputs(
                protectionEnabled = config.enabled,
                paused = config.isPaused(),
                safeMode = config.safeMode,
                vpnState = s.vpnState,
                vpnPermission = permissionIntent() == null,
                dnsFilterActive = s.dnsFilterActive,
                upstreamAvailable = s.upstreamAvailable,
                privateDnsStrict = s.privateDnsStrict,
                otherVpnActive = s.otherVpnActive,
                upstreamFailing = s.vpnState == VpnState.RUNNING && upstreamHealth.isFailing(System.currentTimeMillis()),
                rulesReady = s.rulesReady,
                blockingRuleCount = s.blockingRuleCount,
                customKeywordCount = runCatching { keywords.list().size }.getOrDefault(0),
                searchEnabled = config.searchEffectivelyEnabled,
                aiEnabled = config.effectiveAi.enabled,
                aiTextModelAvailable = contentClassifier.isAvailable(ContentKind.TEXT),
                protectedAppCount = appCount,
                accessibility = a11y,
                databaseOk = databaseOk(),
            ),
        )
    }

    fun detailedStatistics(): DetailedStatistics = statistics.detailed()

    // ---- Continuous health monitoring (Phase 8) -------------------------

    val alerts by lazy { ProtectionAlerts(context, config, ::launchIntent) }
    private val monitorPolicy = HealthMonitorPolicy()
    @Volatile var lastMonitorCheck = 0L
        private set

    /**
     * One monitoring round (worker thread; called by the VPN service every
     * 15 minutes while it runs, and after network changes): detect, repair
     * what can be repaired (bounded backoff), re-check, notify once.
     */
    @Synchronized
    fun monitorTick() {
        val now = System.currentTimeMillis()
        lastMonitorCheck = now
        val expected = config.enabled && !config.safeMode && !config.isPaused()
        var report = health()
        val observation = MonitorObservation(
            report = report,
            protectionExpected = expected,
            aiModelBroken = config.effectiveAi.enabled && !contentClassifier.isAvailable(ContentKind.TEXT),
            databaseFailing = !databaseOk(),
            bundledListsMissing = listsLoaded && bundledLists.isEmpty() && BundledLists.specs.isNotEmpty(),
        )
        var repaired = false
        for (component in monitorPolicy.repairs(observation, now)) {
            val ok = repair(component)
            monitorPolicy.onRepairResult(component, ok, now)
            repaired = repaired || ok
        }
        if (repaired) report = health() // re-check after a successful repair
        for (action in monitorPolicy.notifications(report, expected, now)) {
            when (action) {
                is MonitorAction.Notify -> alerts.showDegraded(action.overall, action.reason)
                MonitorAction.ClearNotification -> alerts.clear()
                is MonitorAction.Repair -> Unit
            }
        }
    }

    private fun repair(c: Repairable): Boolean = try {
        when (c) {
            Repairable.AI_MODEL -> {
                textAdapter.resetFailure()
                contentClassifier.isAvailable(ContentKind.TEXT)
            }
            Repairable.DATABASE -> {
                val ok = database.isHealthy() && runCatching { rules.count() }.isSuccess
                if (ok) lastDatabaseFailureAt = 0
                ok
            }
            Repairable.BUNDLED_LISTS -> {
                bundledLists = loadBundledLists()
                engine.invalidate()
                refreshRuleCounts()
                bundledLists.isNotEmpty()
            }
        }
    } catch (e: RuntimeException) {
        false
    }

    /** Immediate alert for events the user must know about (VPN lost). */
    fun alertStopped(reason: String) {
        if (config.enabled && !config.safeMode && !config.isPaused()) {
            alerts.showDegraded(OverallHealth.NOT_PROTECTED, reason)
        }
    }

    /** Battery optimisation exemption. Some OEMs stop VPN apps that lack it. */
    fun ignoringBatteryOptimizations(): Boolean? = try {
        context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName)
    } catch (e: RuntimeException) {
        null
    }

    /**
     * Local diagnostics for "copy diagnostic information". States, counts and
     * versions only: no domains, queries, package names, keywords or logs.
     * Every probe is guarded so one broken component can't hide the rest.
     */
    fun diagnostics(): Map<String, Any?> {
        fun <T> safe(block: () -> T): Any? = try { block() } catch (e: RuntimeException) { "error:" + e.javaClass.simpleName }
        refreshEnvironment()
        val s = status.current
        return mapOf(
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "vpnState" to s.vpnState.name.lowercase(),
            "vpnPermission" to safe { permissionIntent() == null },
            "dnsFilterActive" to s.dnsFilterActive,
            "upstreamAvailable" to s.upstreamAvailable,
            "upstreamFailing" to upstreamHealth.isFailing(System.currentTimeMillis()),
            "privateDnsStrict" to s.privateDnsStrict,
            "otherVpnActive" to s.otherVpnActive,
            "protectionEnabled" to config.enabled,
            "mode" to config.mode.id,
            "safeMode" to config.safeMode,
            "paused" to config.isPaused(),
            "rulesReady" to s.rulesReady,
            "bundledLists" to bundledLists.associate { it.category.id to it.size },
            "userRules" to safe { rules.count(RuleSource.USER) },
            "keywords" to safe { keywords.list().size },
            "protectedApps" to safe { protectedApps.list().size },
            "accessibility" to safe { accessibilityState().name.lowercase() },
            "searchEnabled" to config.searchEffectivelyEnabled,
            "aiEnabled" to config.effectiveAi.enabled,
            "aiTextModel" to safe { contentClassifier.isAvailable(ContentKind.TEXT) },
            "aiImageModel" to safe { contentClassifier.isAvailable(ContentKind.IMAGE) },
            "shieldState" to safe { shieldStatus().state.id },
            "shieldImageModel" to shieldImage.state.id,
            "shieldAccessibility" to safe { shieldAccessibilityState().name.lowercase() },
            "databaseOk" to safe { databaseOk() },
            "logRetention" to config.logRetention.id,
            "logWriteFailures" to logger.failedWrites,
            "batteryOptimizationIgnored" to ignoringBatteryOptimizations(),
            "openIncidents" to config.incidents.unacknowledged().size,
            "lastBoot" to config.lastBoot?.first,
            "alertsEnabled" to config.alertsEnabled,
            "notificationPermission" to safe { alerts.permissionGranted() },
            "lastHealthCheckMinutesAgo" to lastMonitorCheck.takeIf { it > 0 }?.let { (System.currentTimeMillis() - it) / 60_000 },
        )
    }

    /** Secure defaults for all settings; keeps lists, keywords, apps, logs. */
    fun resetProtection() {
        config.resetSettings()
        contentClassifier.clear()
        status.update { it.copy(enabledCategories = config.effectiveCategories.size) }
    }

    // ---- Custom keywords -------------------------------------------------

    fun addKeyword(raw: String, category: Category) = keywords.add(raw, category).also { backupUserConfig() }

    fun removeKeyword(id: Long) = keywords.remove(id).also { backupUserConfig() }

    // ---- User rules (blocklist / allowlist) ----------------------------

    fun addUserRule(input: String, action: RuleAction, category: Category, includeSubdomains: Boolean = true): Rule {
        val rule = userRules.add(input, action, category, includeSubdomains)
        onRulesChanged()
        backupUserConfig()
        return rule
    }

    fun removeUserRule(domain: String, action: RuleAction): Boolean {
        val removed = userRules.remove(domain, action)
        if (removed) {
            onRulesChanged()
            backupUserConfig()
        }
        return removed
    }

    fun checkDomain(input: String): Decision = engine.evaluate(input, config.policy)

    // ---- Search Protection ---------------------------------------------

    fun setSearchConfig(next: SafeSearchConfig) {
        config.updateSearch(next)
    }

    /** Classifies a *submitted* query; never stores the text. */
    fun submitSearch(text: String, engineId: String): SearchDecision =
        searchFilter.classify(SearchQuery(engineId, text.take(SearchNormalizer.MAX_INPUT)))

    // ---- AI Protection ---------------------------------------------------

    fun setAiSettings(next: AiSettings): AiSettings = config.updateAi(next)

    fun isAiAvailable(kind: ContentKind) = contentClassifier.isAvailable(kind)

    /**
     * Classifies an image the user picked, in memory. Nothing is stored:
     * a BLOCK becomes an event whose subject is the model id plus a keyed
     * short hash of the image digest.
     */
    fun checkImage(bytes: ByteArray, declaredMime: String?): Pair<ClassificationResult, ProtectionDecision> {
        // Validate even when no model is installed, so the user learns
        // whether the file itself is acceptable.
        val result = try {
            imageAdapter.validate(bytes, declaredMime)
            contentClassifier.classifyImage(bytes, declaredMime)
        } catch (e: ImageRejectedException) {
            ClassificationResult.rejected(e.error)
        }
        val decision = ProtectionDecisionEngine.decide(
            rule = RuleSignal.None,
            ai = result,
            policy = DecisionPolicy(config.filteringActive, config.effectiveCategories, config.effectiveAi),
            source = EventSource.AI,
        )
        aiStatsRecorder.onAiDecision(ContentKind.IMAGE, decision)
        if (decision.blocks) {
            val digest = ModelLoader.sha256Hex(bytes)
            logger.record(
                BlockEvent(
                    timestamp = logger.now(),
                    subject = "${decision.modelId ?: "image"}#${hasher.shortHash(digest)}",
                    category = decision.category,
                    source = EventSource.AI,
                    confidence = decision.confidence,
                    ruleType = AiSearchFilterService.RULE_TYPE_AI_IMAGE,
                ),
            )
        }
        return result to decision
    }

    fun reportFalsePositive(source: EventSource, category: Category, confidence: Double) {
        aiStats.addReport(FalsePositiveReport.of(System.currentTimeMillis(), source, category, confidence))
    }

    fun aiStatistics() = aiStats.read()

    // ---- App Protection ------------------------------------------------

    fun protectedApps() = appProtection.list()

    fun addProtectedApp(pkg: String) = appProtection.add(pkg).also { backupUserConfig() }

    fun removeProtectedApp(pkg: String) = appProtection.remove(pkg).also { backupUserConfig() }

    /** Called by the accessibility service on a foreground window change. */
    fun onForegroundApp(pkg: String?): AppDecision {
        val decision = appProtection.decide(pkg, config.filteringActive)
        if (decision.action == AppAction.BLOCK_APP) {
            logger.record(
                BlockEvent(
                    timestamp = logger.now(),
                    subject = decision.packageName,
                    category = Category.UNKNOWN,
                    source = EventSource.APP,
                    ruleType = BlockEvent.RULE_TYPE_PROTECTED_APP,
                ),
            )
        }
        return decision
    }

    /** Launchable apps the user may protect (label + package). */
    fun launchableApps(): List<Pair<String, String>> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        return pm.queryIntentActivities(intent, 0)
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
            .distinctBy { it.first }
            .filterNot { appProtection.isNeverProtectable(it.first) }
            .sortedBy { it.second.lowercase() }
            .map { it.second to it.first }
    }

    fun appLabel(pkg: String): String = try {
        val pm = context.packageManager
        @Suppress("DEPRECATION")
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        pkg
    }

    fun accessibilityState(): AccessibilityState {
        val am = context.getSystemService(AccessibilityManager::class.java)
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        return AccessibilityStateResolver.resolve(
            frameworkAvailable = am != null,
            enabledServices = enabled,
            ourComponent = ComponentName(context, AppGuardService::class.java).flattenToString(),
            disclosureDeclined = config.accessibilityDisclosureDeclined,
        )
    }

    // ---- AI Content Shield ---------------------------------------------

    /** Packages the shield's accessibility service should receive events from (empty when off). */
    fun shieldPackages(): List<String> = config.shieldSettings.monitoredPackages()

    /** Whether screen content may be read right now (protection on, not paused, AI on). */
    fun shieldContentActive(): Boolean = config.filteringActive && config.effectiveAi.enabled

    fun shieldAccessibilityState(): AccessibilityState {
        val am = context.getSystemService(AccessibilityManager::class.java)
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        return AccessibilityStateResolver.resolve(
            frameworkAvailable = am != null,
            enabledServices = enabled,
            ourComponent = ComponentName(context, ContentShieldService::class.java).flattenToString(),
            disclosureDeclined = config.shieldDisclosureDeclined,
        )
    }

    /** The shield's real state (never ACTIVE while image AI is unavailable). */
    fun shieldStatus(): ShieldStatus {
        val a11y = shieldAccessibilityState()
        return ShieldStatusResolver.resolve(
            settings = config.shieldSettings,
            protectionActive = config.filteringActive,
            aiEnabled = config.effectiveAi.enabled,
            accessibilityEnabled = a11y == AccessibilityState.ENABLED,
            accessibilityAvailable = a11y != AccessibilityState.UNAVAILABLE,
            textModelAvailable = contentClassifier.isAvailable(ContentKind.TEXT),
            imageModelAvailable = shieldImage.isUsable,
            screenCaptureActive = ScreenCaptureService.running,
            textSlow = shield.textSlow,
            imageSlow = shield.imageSlow,
        )
    }

    val shieldImageModelState: ImageModelState get() = shieldImage.state

    /** Turning the shield off (or an app off) needs the PIN; the UI checks it. */
    fun setShieldEnabled(enabled: Boolean) {
        config.shieldSettings = config.shieldSettings.copy(enabled = enabled)
        if (enabled) config.shieldDisclosureDeclined = false
        onShieldStateChanged()
    }

    fun setShieldAppEnabled(key: String, enabled: Boolean) {
        require(SupportedApps.byKey(key) != null) { "unknown app" }
        val s = config.shieldSettings
        config.shieldSettings = s.copy(disabledApps = if (enabled) s.disabledApps - key else s.disabledApps + key)
        onShieldStateChanged()
    }

    /** Image checks in every app. Turning it off needs the PIN (UI). */
    fun setShieldAllApps(on: Boolean) {
        config.shieldSettings = config.shieldSettings.copy(allApps = on)
        onShieldStateChanged()
    }

    /** Maximum image sensitivity. Turning it off needs the PIN (UI). */
    fun setShieldMaxSensitivity(on: Boolean) {
        config.shieldSettings = config.shieldSettings.copy(maxSensitivity = on)
    }

    fun declineShieldDisclosure() {
        config.shieldDisclosureDeclined = true
    }

    /**
     * Logs a shield block (metadata only: time, app, category, confidence
     * bucket, model version). Returns false if protection stopped in the
     * meantime, in which case nothing is blocked.
     */
    fun onShieldBlock(e: ShieldEvent, action: BlockAction): Boolean {
        if (!shield.isActiveFor(e.packageName, e.kind)) return false
        logger.record(
            BlockEvent(
                timestamp = e.timestamp,
                subject = e.packageName,
                category = e.category,
                source = EventSource.AI,
                confidence = e.confidenceBucket / 100.0,
                ruleType = "${e.ruleType}:${action.id}",
            ),
        )
        return true
    }

    /**
     * A query typed into a supported app's search box (checked once typing
     * pauses). Null when the shield doesn't cover the app right now.
     */
    fun shieldSearch(pkg: String, query: String): SearchDecision? {
        val app = SupportedApps.forPackage(pkg) ?: return null
        if (!shield.isActiveFor(pkg, ContentKind.TEXT)) return null
        return appSearchFilter.classify(SearchQuery("app:${app.key}", query.take(SearchNormalizer.MAX_INPUT)))
    }

    /** Screen capture started or stopped: free the image model when it can't be used. */
    fun onScreenCaptureChanged() {
        if (!ScreenCaptureService.running) shieldImage.close()
    }

    /**
     * Protection, pause or shield settings changed: re-apply to the
     * services; end screen capture when the shield or protection is turned
     * off (a pause only detaches it); free the models when idle.
     */
    private fun onShieldStateChanged() {
        if (!config.shieldSettings.enabled || !config.enabled) ScreenCaptureService.stop()
        if (!config.shieldSettings.enabled || !shieldContentActive()) shield.release()
        ContentShieldService.refresh()
        ScreenCaptureService.updateActive()
    }

    /** Memory-maps an uncompressed asset (falls back to a direct copy if it is compressed). */
    private fun mapAsset(pack: ImageModelPack): ByteBuffer? = try {
        context.assets.openFd(pack.assetPath).use { fd ->
            FileInputStream(fd.fileDescriptor).channel.use { ch ->
                ch.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
            }
        }
    } catch (e: java.io.IOException) {
        // openFd fails for compressed assets (FileNotFoundException too): copy instead.
        try {
            context.assets.open(pack.assetPath).use { input ->
                val bytes = input.readBytes()
                ByteBuffer.allocateDirect(bytes.size).put(bytes).also { it.rewind() }
            }
        } catch (missing: java.io.IOException) {
            null
        }
    }

    /** Launchers, the default dialer: blocking them would lock the owner out. */
    @Volatile private var exemptCache: Pair<Long, Set<String>>? = null

    /**
     * Launcher + default dialer. Called on every foreground-app event (main
     * thread), so the package-manager query is cached for a minute: the
     * default home/dialer app changes rarely.
     */
    private fun deviceExemptPackages(): Set<String> {
        val now = SystemClock.elapsedRealtime()
        exemptCache?.let { (at, set) -> if (now - at < 60_000) return set }
        return queryExemptPackages().also { exemptCache = now to it }
    }

    private fun queryExemptPackages(): Set<String> {
        val pm = context.packageManager
        val out = HashSet<String>()
        @Suppress("DEPRECATION")
        pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)
            .forEach { out += it.activityInfo.packageName }
        try {
            context.getSystemService(TelecomManager::class.java)?.defaultDialerPackage?.let { out += it }
        } catch (e: SecurityException) {
            // Not available on this device.
        }
        return out
    }

    // ---- Logs & statistics ---------------------------------------------

    fun recentBlocks(limit: Int) = events.recent(limit)

    fun statistics(): BlockStatistics = statistics.compute()

    fun setLogRetention(value: LogRetention) {
        config.logRetention = value
        logger.applyRetention()
        if (!value.keepsLog) logger.reset()
        onActivity() // the log may have been pruned
    }

    fun clearLogs() {
        events.clear()
        aiStats.clear()
        contentClassifier.clear()
        shieldText.clear()
        logger.reset()
        onActivity()
    }

    /** Called when the user erases all app data from Flutter. */
    fun eraseAll() {
        backupFile.delete() // must not come back after "delete all data"
        stop()
        events.clear()
        aiStats.clear()
        contentClassifier.clear()
        keywords.clear()
        rules.deleteSource(RuleSource.USER)
        protectedApps.clear()
        config.clear()
        shieldText.clear()
        onShieldStateChanged() // the shield is off again after a full erase
        hmacKey.rotate()
        onRulesChanged()
    }

    fun launchIntent(): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    // ---- Internals -----------------------------------------------------

    // ---- User configuration backup (Phase 8) ---------------------------

    /** Private, never backed up to the cloud (noBackupFilesDir). */
    private val backupFile get() = File(context.noBackupFilesDir, "user-config.bak")

    /** Writes the user's lists, keywords and protected apps (atomic replace). */
    private fun backupUserConfig() {
        try {
            val config = UserConfig(
                rules = rules.list(RuleSource.USER, null, 5000, 0).map {
                    UserRuleEntry(it.domain, it.action, it.category, it.includeSubdomains)
                },
                keywords = keywords.list().map { KeywordEntry(it.phrase, it.category) },
                protectedApps = protectedApps.list().map { it.packageName },
            )
            val tmp = File(backupFile.path + ".tmp")
            tmp.writeText(UserConfigBackup.encode(config))
            if (!tmp.renameTo(backupFile)) {
                backupFile.delete()
                tmp.renameTo(backupFile)
            }
        } catch (e: Exception) {
            Log.w("SafeGuard", "config backup failed: ${e.javaClass.simpleName}")
        }
    }

    /**
     * After the database was (re)created: bring back the user's own
     * configuration. Each entry is re-validated; nothing is restored over
     * existing user data.
     */
    private fun restoreUserConfig() {
        try {
            if (!backupFile.isFile || rules.count(RuleSource.USER) > 0) return
            val config = UserConfigBackup.decode(backupFile.readText()) ?: return
            val now = System.currentTimeMillis()
            rules.upsertAll(
                config.rules.map {
                    Rule(it.domain, it.category, it.action, source = RuleSource.USER, updatedAt = now, includeSubdomains = it.includeSubdomains)
                },
            )
            for (k in config.keywords) runCatching { keywords.add(k.phrase, k.category) }
            for (a in config.protectedApps) runCatching { protectedApps.add(ProtectedApp(a, now)) }
            engine.invalidate()
        } catch (e: Exception) {
            Log.w("SafeGuard", "config restore failed: ${e.javaClass.simpleName}")
        }
    }

    private fun onRulesChanged() {
        engine.invalidate()
        refreshRuleCounts()
    }

    /** Never throws: a database error only leaves the counts at the lists. */
    private fun refreshRuleCounts() {
        val listed = bundledLists.sumOf { it.size }
        val (count, blocking) = try {
            rules.count() to rules.countBlocking()
        } catch (e: RuntimeException) {
            onDatabaseFailure(e)
            0 to 0
        }
        status.update {
            // "Ready" only once the bundled lists are in: before that most
            // category blocking isn't active yet.
            it.copy(rulesReady = listsLoaded, ruleCount = count + listed, blockingRuleCount = blocking + listed)
        }
    }

    /**
     * Maps each bundled list asset (uncompressed in the APK, so no heap
     * copy), checks its pinned size and SHA-256, and validates it. A list
     * that fails any check is skipped — never partially used.
     */
    private fun loadBundledLists(): List<HashedDomainList> = BundledLists.specs.mapNotNull { spec ->
        try {
            val buffer: ByteBuffer = try {
                context.assets.openFd(spec.assetPath).use { fd ->
                    FileInputStream(fd.fileDescriptor).channel.use { ch ->
                        ch.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
                    }
                }
            } catch (e: java.io.IOException) {
                // Asset stored compressed: fall back to reading it into memory.
                ByteBuffer.wrap(context.assets.open(spec.assetPath).use { it.readBytes() })
            }
            if (buffer.capacity().toLong() != spec.sizeBytes) throw IllegalStateException("size mismatch")
            val digest = MessageDigest.getInstance("SHA-256").apply { update(buffer.duplicate()) }.digest()
                .joinToString("") { "%02x".format(it) }
            if (digest != spec.sha256) throw IllegalStateException("checksum mismatch")
            HashedDomainList.parse(buffer).takeIf { it.size == spec.entries && it.category == spec.category }
        } catch (e: Exception) {
            Log.e("SafeGuard", "bundled list ${spec.assetPath} unusable: ${e.javaClass.simpleName}")
            null
        }
    }

    private fun seedBuiltInRules() {
        try {
            val seeded = database.getMeta(META_BUILTIN_VERSION)?.toIntOrNull()
            val debugSeeded = database.getMeta(META_TEST_FIXTURES) == "1"
            val now = System.currentTimeMillis()
            if (seeded != BuiltInRules.VERSION) {
                rules.deleteSource(RuleSource.BUILT_IN)
                rules.upsertAll(BuiltInRules.production(now))
                database.setMeta(META_BUILTIN_VERSION, BuiltInRules.VERSION.toString())
            }
            if (isDebuggable && (!debugSeeded || seeded != BuiltInRules.VERSION)) {
                rules.deleteSource(RuleSource.TEST)
                rules.upsertAll(BuiltInRules.testFixtures(now))
                database.setMeta(META_TEST_FIXTURES, "1")
            } else if (!isDebuggable && debugSeeded) {
                rules.deleteSource(RuleSource.TEST)
                database.setMeta(META_TEST_FIXTURES, "0")
            }
        } catch (e: Exception) {
            Log.e("SafeGuard", "seeding rules failed: ${e.javaClass.simpleName}")
        }
    }

    companion object {
        private const val META_BUILTIN_VERSION = "builtin_version"
        private const val META_TEST_FIXTURES = "test_fixtures"

        @Volatile private var instance: ProtectionManager? = null

        fun get(context: Context): ProtectionManager =
            instance ?: synchronized(this) {
                instance ?: ProtectionManager(context.applicationContext).also { instance = it }
            }
    }
}
