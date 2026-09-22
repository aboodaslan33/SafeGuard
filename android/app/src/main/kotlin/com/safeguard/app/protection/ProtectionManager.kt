package com.safeguard.app.protection

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.app.PendingIntent
import android.net.VpnService
import android.util.Log
import com.safeguard.app.MainActivity
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
import com.safeguard.app.engine.search.NoOpSearchFilterService
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

    /** Phase 3 seam; inactive placeholder today. */
    val searchFilter: SearchFilterService = NoOpSearchFilterService

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

    /** Re-checks conditions outside our control (other VPN, Private DNS, network). */
    fun refreshEnvironment(upstream: UpstreamNetwork? = null) {
        val running = status.current.vpnState == VpnState.RUNNING
        status.update {
            it.copy(
                otherVpnActive = NetworkMonitor.otherVpnActive(context, running),
                privateDnsStrict = upstream?.privateDnsStrict ?: (if (running) it.privateDnsStrict else false),
                upstreamAvailable = if (running) upstream != null else it.upstreamAvailable,
            )
        }
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

    // ---- Logs & statistics ---------------------------------------------

    fun recentBlocks(limit: Int) = events.recent(limit)

    fun statistics(): BlockStatistics = statistics.compute()

    fun clearLogs() {
        events.clear()
        logger.reset()
    }

    /** Called when the user erases all app data from Flutter. */
    fun eraseAll() {
        stop()
        events.clear()
        rules.deleteSource(RuleSource.USER)
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
