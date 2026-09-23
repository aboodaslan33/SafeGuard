package com.safeguard.app.engine.explain

import com.safeguard.app.engine.logging.BlockEvent
import com.safeguard.app.engine.logging.EventSource
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.Decision
import com.safeguard.app.engine.rules.DecisionReason
import com.safeguard.app.engine.search.SearchDecision

enum class Verdict { BLOCKED, ALLOWED }

/**
 * One stable, user-explainable reason for every decision SafeGuard makes,
 * whichever layer made it (DNS rules, search rules, keywords, AI, app
 * protection). The UI translates [id]; nothing here exposes model
 * internals (weights, features, raw scores beyond the shown confidence).
 */
enum class Explanation(val id: String, val verdict: Verdict) {
    PROTECTION_OFF("protection_off", Verdict.ALLOWED),
    INVALID_REQUEST("invalid_request", Verdict.ALLOWED),
    USER_ALLOWED("user_allowed", Verdict.ALLOWED),
    USER_BLOCKED_DOMAIN("user_blocked_domain", Verdict.BLOCKED),
    KNOWN_BLOCKED_DOMAIN("known_blocked_domain", Verdict.BLOCKED),
    KNOWN_SAFE_DOMAIN("known_safe_domain", Verdict.ALLOWED),
    CATEGORY_DISABLED("category_disabled", Verdict.ALLOWED),
    CLASSIFIED_DOMAIN("classified_domain", Verdict.BLOCKED),
    STRICT_UNKNOWN_DOMAIN("strict_unknown_domain", Verdict.BLOCKED),
    NO_MATCH("no_match", Verdict.ALLOWED),
    CUSTOM_KEYWORD("custom_keyword", Verdict.BLOCKED),
    SEARCH_RULE("search_rule", Verdict.BLOCKED),
    SEARCH_BELOW_THRESHOLD("search_below_threshold", Verdict.ALLOWED),
    AI_ABOVE_THRESHOLD("ai_above_threshold", Verdict.BLOCKED),
    AI_BELOW_THRESHOLD("ai_below_threshold", Verdict.ALLOWED),
    AI_UNCERTAIN("ai_uncertain", Verdict.ALLOWED),
    AI_UNAVAILABLE("ai_unavailable", Verdict.ALLOWED),
    AI_SAFE("ai_safe", Verdict.ALLOWED),
    PROTECTED_APP("protected_app", Verdict.BLOCKED),
    AI_CONTENT_SHIELD("ai_content_shield", Verdict.BLOCKED),
    TEMPORARY_UNLOCK("temporary_unlock", Verdict.ALLOWED);

    companion object {
        fun fromId(id: String?) = entries.firstOrNull { it.id == id }
    }
}

object DecisionExplainer {
    /** Rule types stored on DNS block events (finer than "domain"). */
    const val RULE_TYPE_USER_DOMAIN = "user_domain"
    const val RULE_TYPE_CLASSIFIED_DOMAIN = "classified_domain"
    const val RULE_TYPE_STRICT_UNKNOWN = "strict_unknown"

    /** AI Content Shield events: `ai_shield:<kind>:<label>:<model>` (see ShieldEvent). */
    const val SHIELD_RULE_TYPE_PREFIX = "ai_shield:"

    fun domain(d: Decision): Explanation = when (d.reason) {
        DecisionReason.PROTECTION_OFF -> Explanation.PROTECTION_OFF
        DecisionReason.INVALID_DOMAIN -> Explanation.INVALID_REQUEST
        DecisionReason.ALLOWLISTED -> Explanation.USER_ALLOWED
        DecisionReason.USER_BLOCKLIST -> Explanation.USER_BLOCKED_DOMAIN
        DecisionReason.CATEGORY_BLOCKED -> Explanation.KNOWN_BLOCKED_DOMAIN
        DecisionReason.CATEGORY_DISABLED -> Explanation.CATEGORY_DISABLED
        DecisionReason.SAFE_RULE -> Explanation.KNOWN_SAFE_DOMAIN
        DecisionReason.CLASSIFIED_BLOCKED -> Explanation.CLASSIFIED_DOMAIN
        DecisionReason.UNKNOWN_ALLOWED -> Explanation.NO_MATCH
        DecisionReason.UNKNOWN_BLOCKED_STRICT -> Explanation.STRICT_UNKNOWN_DOMAIN
    }

    /** Rule type recorded for a DNS block, so the log can explain it later. */
    fun domainRuleType(d: Decision): String = when (d.reason) {
        DecisionReason.USER_BLOCKLIST -> RULE_TYPE_USER_DOMAIN
        DecisionReason.CLASSIFIED_BLOCKED -> RULE_TYPE_CLASSIFIED_DOMAIN
        DecisionReason.UNKNOWN_BLOCKED_STRICT -> RULE_TYPE_STRICT_UNKNOWN
        else -> BlockEvent.RULE_TYPE_DOMAIN
    }

    fun search(d: SearchDecision): Explanation = when (d.ruleType) {
        "custom_keyword" -> Explanation.CUSTOM_KEYWORD
        "ai_text", "ai_image" -> when (d.reason) {
            "ai_threshold" -> Explanation.AI_ABOVE_THRESHOLD
            "below_threshold" -> Explanation.AI_BELOW_THRESHOLD
            "ai_uncertain" -> Explanation.AI_UNCERTAIN
            "ai_unavailable" -> Explanation.AI_UNAVAILABLE
            "ai_safe" -> Explanation.AI_SAFE
            else -> Explanation.NO_MATCH
        }
        else -> when (d.reason) {
            "category_blocked" -> Explanation.SEARCH_RULE
            "below_threshold" -> Explanation.SEARCH_BELOW_THRESHOLD
            "category_disabled" -> Explanation.CATEGORY_DISABLED
            "search_protection_off" -> Explanation.PROTECTION_OFF
            else -> Explanation.NO_MATCH
        }
    }

    /** Explanation for a stored log event (which keeps only its rule type). */
    fun event(source: EventSource, ruleType: String): Explanation = when (ruleType) {
        RULE_TYPE_USER_DOMAIN -> Explanation.USER_BLOCKED_DOMAIN
        RULE_TYPE_CLASSIFIED_DOMAIN -> Explanation.CLASSIFIED_DOMAIN
        RULE_TYPE_STRICT_UNKNOWN -> Explanation.STRICT_UNKNOWN_DOMAIN
        BlockEvent.RULE_TYPE_DOMAIN -> Explanation.KNOWN_BLOCKED_DOMAIN
        "custom_keyword" -> Explanation.CUSTOM_KEYWORD
        "keyword" -> Explanation.SEARCH_RULE
        "ai_text", "ai_image" -> Explanation.AI_ABOVE_THRESHOLD
        BlockEvent.RULE_TYPE_PROTECTED_APP -> Explanation.PROTECTED_APP
        BlockEvent.RULE_TYPE_TEMPORARY_UNLOCK -> Explanation.TEMPORARY_UNLOCK
        else -> if (ruleType.startsWith(SHIELD_RULE_TYPE_PREFIX)) Explanation.AI_CONTENT_SHIELD else if (source == EventSource.DNS) Explanation.KNOWN_BLOCKED_DOMAIN else Explanation.NO_MATCH
    }

    /** Pipeline stages in evaluation order, up to the one that decided. */
    fun stages(e: Explanation): List<String> {
        val dns = listOf("protection", "allowlist", "user_blocklist", "lists", "classifier", "unknown_policy")
        val search = listOf("protection", "custom_keywords", "search_rules", "ai")
        fun upTo(pipeline: List<String>, stage: String) = pipeline.subList(0, pipeline.indexOf(stage) + 1)
        return when (e) {
            Explanation.PROTECTION_OFF, Explanation.INVALID_REQUEST -> listOf("protection")
            Explanation.USER_ALLOWED -> upTo(dns, "allowlist")
            Explanation.USER_BLOCKED_DOMAIN -> upTo(dns, "user_blocklist")
            Explanation.KNOWN_BLOCKED_DOMAIN, Explanation.KNOWN_SAFE_DOMAIN -> upTo(dns, "lists")
            Explanation.CLASSIFIED_DOMAIN -> upTo(dns, "classifier")
            Explanation.STRICT_UNKNOWN_DOMAIN -> dns
            Explanation.CUSTOM_KEYWORD -> upTo(search, "custom_keywords")
            Explanation.SEARCH_RULE, Explanation.SEARCH_BELOW_THRESHOLD -> upTo(search, "search_rules")
            Explanation.AI_ABOVE_THRESHOLD, Explanation.AI_BELOW_THRESHOLD, Explanation.AI_UNCERTAIN,
            Explanation.AI_UNAVAILABLE, Explanation.AI_SAFE -> search
            Explanation.PROTECTED_APP -> listOf("app_protection")
            Explanation.AI_CONTENT_SHIELD -> listOf("protection", "content_shield", "ai", "policy")
            Explanation.TEMPORARY_UNLOCK -> listOf("pause")
            Explanation.CATEGORY_DISABLED, Explanation.NO_MATCH -> listOf("all")
        }
    }
}

/**
 * Content-free record of one decision for debugging: *what* decided and
 * *why*, never *what was requested* — no domain, query, package or text.
 */
data class TraceEntry(
    val timestamp: Long,
    val source: EventSource,
    val explanation: Explanation,
    val category: Category,
    /** Confidence rounded down to 10 % steps (0–100), or null for exact rules. */
    val confidenceBucket: Int?,
    val stages: List<String>,
)

/**
 * In-memory ring buffer of recent decisions. Off by default; turning it
 * off clears it; never written to disk or the log.
 */
class DecisionTrace(private val capacity: Int = 50) {
    @Volatile var enabled: Boolean = false
        set(value) {
            field = value
            if (!value) clear()
        }

    private val entries = ArrayDeque<TraceEntry>()

    fun recordDomain(d: Decision, now: Long) {
        if (!enabled) return
        val e = DecisionExplainer.domain(d)
        add(TraceEntry(now, EventSource.DNS, e, d.category, null, DecisionExplainer.stages(e)))
    }

    fun recordSearch(d: SearchDecision, now: Long) {
        if (!enabled) return
        val e = DecisionExplainer.search(d)
        val bucket = if (d.ruleType.startsWith("ai_")) (d.confidence.coerceIn(0.0, 1.0) * 10).toInt() * 10 else null
        val source = if (d.ruleType.startsWith("ai_")) EventSource.AI else EventSource.SEARCH
        add(TraceEntry(now, source, e, d.category, bucket, DecisionExplainer.stages(e)))
    }

    @Synchronized fun snapshot(): List<TraceEntry> = entries.toList().asReversed()

    @Synchronized fun clear() = entries.clear()

    @Synchronized private fun add(e: TraceEntry) {
        if (entries.size >= capacity) entries.removeFirst()
        entries.addLast(e)
    }
}
