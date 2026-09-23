package com.safeguard.app.protection

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.telecom.TelecomManager
import android.view.accessibility.AccessibilityManager
import android.content.pm.ApplicationInfo
import android.app.PendingIntent
import android.net.VpnService
import android.os.SystemClock
import android.util.Log
import com.safeguard.app.MainActivity
import com.safeguard.app.engine.rules.BundledListStore
import com.safeguard.app.engine.rules.BundledLists
import com.safeguard.app.engine.rules.CompositeRuleStore
import com.safeguard.app.engine.rules.HashedDomainList
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest
import com.safeguard.app.data.SqliteCustomKeywordStore
import com.safeguard.app.engine.health.HealthInputs
import com.safeguard.app.engine.health.HealthReport
import com.safeguard.app.engine.health.Incident
import com.safeguard.app.engine.health.IncidentDetector
import com.safeguard.app.engine.health.IncidentKind
import com.safeguard.app.engine.health.ProtectionHealthEvaluator
import com.safeguard.app.engine.health.RecoveryPolicy
import com.safeguard.app.engine.health.UpstreamHealth
import com.safeguard.app.engine.modes.ProtectionMode
import com.safeguard.app.engine.pause.TemporaryUnlock
import com.safeguard.app.engine.rules.UserRules
import com.safeguard.app.engine.search.CustomKeywords
import com.safeguard.app.engine.stats.DetailedStatistics
import com.safeguard.app.ai.BitmapImageDecoder
import com.safeguard.app.data.SqliteAiStatsStore
import com.safeguard.app.engine.ai.AdapterContentClassifier
import com.safeguard.app.engine.ai.AiSearchFilterService
import com.safeguard.app.engine.ai.AiSettings
import com.safeguard.app.engine.ai.AiStatsRecorder
import com.safeguard.app.engine.ai.ClassificationResult
import com.safeguard.app.engine.ai.ContentKind
import com.safeguard.app.engine.ai.DecisionPolicy
import com.safeguard.app.engine.ai.FalsePositiveReport
import com.safeguard.app.engine.ai.GuardedContentClassifier
import com.safeguard.app.engine.ai.ProtectionDecision
import com.safeguard.app.engine.ai.ProtectionDecisionEngine
import com.safeguard.app.engine.ai.RuleSignal
import com.safeguard.app.engine.ai.image.ImageRejectedException
import com.safeguard.app.engine.ai.image.LocalImageClassifierAdapter
import com.safeguard.app.engine.ai.model.BuiltInModels
import com.safeguard.app.engine.ai.model.ModelLoader
import com.safeguard.app.engine.ai.text.LocalTextClassifierAdapter
import com.safeguard.app.engine.ai.text.TextModel
import com.safeguard.app.apps.AppGuardService
import com.safeguard.app.data.SqliteProtectedAppStore
import com.safeguard.app.engine.apps.AccessibilityState
import com.safeguard.app.engine.apps.AccessibilityStateResolver
import com.safeguard.app.engine.apps.AppAction
import com.safeguard.app.engine.apps.AppDecision
import com.safeguard.app.engine.apps.AppProtection
import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.logging.LogRetention
import com.safeguard.app.engine.privacy.QueryHasher
import com.safeguard.app.engine.privacy.SearchEventRecorder
import com.safeguard.app.engine.safesearch.SafeSearchConfig
import com.safeguard.app.engine.search.RuleBasedSearchClassifier
import com.safeguard.app.engine.search.SearchDecision
import com.safeguard.app.engine.search.SearchNormalizer
import com.safeguard.app.engine.search.SearchQuery
import com.safeguard.app.data.SafeGuardDatabase
import com.safeguard.app.data.SqliteBlockEventStore
import com.safeguard.app.data.SqliteRuleStore
import com.safeguard.app.engine.domain.DomainName
import com.safeguard.app.engine.logging.BlockLogger
import com.safeguard.app.engine.rules.BuiltInRules
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.Rule
import com.safeguard.app.engine.rules.RuleAction
import com.safeguard.app.engine.rules.RuleEngine
import com.safeguard.app.engine.rules.RuleSource
import com.safeguard.app.engine.search.SearchFilterService
import com.safeguard.app.engine.stats.BlockStatistics
import com.safeguard.app.engine.stats.StatisticsService
import com.safeguard.app.engine.status.ProtectionStatusHolder
import com.safeguard.app.engine.status.VpnState
import com.safeguard.app.vpn.NetworkMonitor
import com.safeguard.app.vpn.SafeGuardVpnService
import com.safeguard.app.vpn.UpstreamNetwork
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

    /** Non-exportable Keystore HMAC key (event ids, AI cache keys). */
    private val hmacKey = KeystoreHmacKey(context)
    private val hasher = QueryHasher(hmacKey)

    // ---- AI (Phase 4): on-device only, on demand only -------------------

    private val aiStats = SqliteAiStatsStore(database)
    private val aiStatsRecorder = AiStatsRecorder(aiStats)

    /**
     * Local adapters only. The text model loads lazily from APK assets after
     * its size and SHA-256 are verified; no image model ships in this
     * version (the image adapter validates input and reports NO_MODEL). No
     * cloud adapter is registered.
     */
    private val imageAdapter = LocalImageClassifierAdapter("local-image", BitmapImageDecoder(), { null })

    val contentClassifier = GuardedContentClassifier(
        AdapterContentClassifier(
            listOf(
                LocalTextClassifierAdapter(BuiltInModels.TEXT_V1.id, {
                    TextModel.parse(ModelLoader { path -> context.assets.open(path) }.load(BuiltInModels.TEXT_V1))
                }),
                imageAdapter,
            ),
        ),
        macs = hmacKey,
    )

    val keywords = CustomKeywords(SqliteCustomKeywordStore(database))

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
        listener = SearchEventRecorder(logger, hasher),
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
        logger.applyRetention()
        seedBuiltInRules()
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
        return true
    }

    fun stop() {
        config.update(enabled = false)
        status.update { it.copy(protectionEnabled = false) }
        SafeGuardVpnService.stop(context)
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
        return p
    }

    fun endPause() = config.endPause()

    /**
     * Safe Mode: stops the VPN so a filtering problem can't keep the device
     * offline, and blocks automatic restarts until [start] is called.
     */
    fun enterSafeMode() {
        config.safeMode = true
        SafeGuardVpnService.stop(context)
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

    /** Secure defaults for all settings; keeps lists, keywords, apps, logs. */
    fun resetProtection() {
        config.resetSettings()
        contentClassifier.clear()
        status.update { it.copy(enabledCategories = config.effectiveCategories.size) }
    }

    // ---- Custom keywords -------------------------------------------------

    fun addKeyword(raw: String, category: Category) = keywords.add(raw, category)

    fun removeKeyword(id: Long) = keywords.remove(id)

    // ---- User rules (blocklist / allowlist) ----------------------------

    fun addUserRule(input: String, action: RuleAction, category: Category, includeSubdomains: Boolean = true): Rule {
        val rule = userRules.add(input, action, category, includeSubdomains)
        onRulesChanged()
        return rule
    }

    fun removeUserRule(domain: String, action: RuleAction): Boolean {
        val removed = userRules.remove(domain, action)
        if (removed) onRulesChanged()
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

    fun addProtectedApp(pkg: String) = appProtection.add(pkg)

    fun removeProtectedApp(pkg: String) = appProtection.remove(pkg)

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
    }

    fun clearLogs() {
        events.clear()
        aiStats.clear()
        contentClassifier.clear()
        logger.reset()
    }

    /** Called when the user erases all app data from Flutter. */
    fun eraseAll() {
        stop()
        events.clear()
        aiStats.clear()
        contentClassifier.clear()
        keywords.clear()
        rules.deleteSource(RuleSource.USER)
        protectedApps.clear()
        config.clear()
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
