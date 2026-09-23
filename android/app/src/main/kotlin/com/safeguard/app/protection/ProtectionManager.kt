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
import android.util.Log
import com.safeguard.app.MainActivity
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

/** Why a rule change was refused. Surfaced to Flutter as error codes. */
class RuleValidationException(val code: String, message: String) : IllegalArgumentException(message)

/**
 * Process-wide facade over the native protection stack. Both the VPN
 * service and the Flutter channel talk to this object only.
 */
class ProtectionManager private constructor(private val context: Context) {

    val config = ProtectionConfigStore(context)
    private val database = SafeGuardDatabase(context)
    val rules = SqliteRuleStore(database)
    val engine = RuleEngine(rules)
    private val events = SqliteBlockEventStore(database)
    private val logExecutor = Executors.newSingleThreadExecutor { Thread(it, "sg-block-log").apply { isDaemon = true } }
    val logger = BlockLogger(events, logExecutor)
    private val statistics = StatisticsService(events)
    val status = ProtectionStatusHolder()

    private val hasher = QueryHasher(config.hashKey())

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
        key = config.hashKey(),
    )

    /** Search filtering: rule layer first, then the on-device text model. */
    val searchFilter: SearchFilterService = AiSearchFilterService(
        rules = RuleBasedSearchClassifier(),
        config = { config.searchPolicy },
        ai = contentClassifier,
        aiSettings = { config.rawAi },
        listener = SearchEventRecorder(logger, hasher),
        aiListener = aiStatsRecorder,
    )

    private val protectedApps = SqliteProtectedAppStore(database)
    val appProtection = AppProtection(
        store = protectedApps,
        isInstalled = { pkg -> context.packageManager.getLaunchIntentForPackage(pkg) != null },
        neverProtect = ::deviceExemptPackages,
    )

    private val isDebuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    init {
        seedBuiltInRules()
        refreshRuleCounts()
        status.update { it.copy(protectionEnabled = config.enabled, enabledCategories = config.policy.blockedCategories.size) }
    }

    // ---- VPN lifecycle -------------------------------------------------

    /** Intent to show the system VPN consent dialog, or null if granted. */
    fun permissionIntent(): Intent? = VpnService.prepare(context)

    /** Starts the VPN. Returns false if consent is required first. */
    fun start(): Boolean {
        config.update(enabled = true)
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

    fun setConfiguration(enabled: Boolean, categories: Set<Category>) {
        val policy = config.update(enabled = enabled, categories = categories)
        status.update { it.copy(protectionEnabled = policy.enabled, enabledCategories = policy.blockedCategories.size) }
    }

    fun setCategory(category: Category, enabled: Boolean) {
        require(category.isFilterable) { "not a filterable category" }
        val policy = config.setCategory(category, enabled)
        status.update { it.copy(enabledCategories = policy.blockedCategories.size) }
    }

    // ---- User rules (blocklist / allowlist) ----------------------------

    fun addUserRule(input: String, action: RuleAction, category: Category): Rule {
        val domain = DomainName.parseRuleDomain(input)
            ?: throw RuleValidationException("INVALID_DOMAIN", "Not a valid domain name")
        if (action == RuleAction.BLOCK && !category.isFilterable) {
            throw RuleValidationException("INVALID_CATEGORY", "Blocked domains need a content category")
        }
        if (rules.count(RuleSource.USER) >= MAX_USER_RULES) {
            throw RuleValidationException("LIMIT_REACHED", "Too many custom rules")
        }
        // A domain is either allowed or blocked by the user, never both.
        rules.delete(domain, RuleSource.USER)
        val rule = Rule(
            domain = domain,
            category = if (action == RuleAction.ALLOW) Category.SAFE else category,
            action = action,
            source = RuleSource.USER,
            updatedAt = System.currentTimeMillis(),
        )
        rules.upsert(rule)
        onRulesChanged()
        return rule
    }

    fun removeUserRule(domain: String, action: RuleAction): Boolean {
        val existing = rules.get(domain, RuleSource.USER) ?: return false
        if (existing.action != action) return false
        val removed = rules.delete(domain, RuleSource.USER)
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
            policy = DecisionPolicy(config.enabled, config.policy.blockedCategories, config.rawAi),
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
        val decision = appProtection.decide(pkg, config.enabled)
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
    private fun deviceExemptPackages(): Set<String> {
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
        rules.deleteSource(RuleSource.USER)
        protectedApps.clear()
        config.clear()
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

    private fun refreshRuleCounts() {
        status.update {
            it.copy(rulesReady = true, ruleCount = rules.count(), blockingRuleCount = rules.countBlocking())
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
            Log.e("SafeGuard", "seeding rules failed", e)
        }
    }

    companion object {
        private const val META_BUILTIN_VERSION = "builtin_version"
        private const val META_TEST_FIXTURES = "test_fixtures"
        const val MAX_USER_RULES = 2000

        @Volatile private var instance: ProtectionManager? = null

        fun get(context: Context): ProtectionManager =
            instance ?: synchronized(this) {
                instance ?: ProtectionManager(context.applicationContext).also { instance = it }
            }
    }
}
