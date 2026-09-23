package com.safeguard.app.engine.rules

import com.safeguard.app.engine.domain.DomainName

/** Why a custom domain rule was refused. [code] is the Flutter error code. */
enum class UserRuleError(val code: String) {
    INVALID_DOMAIN("INVALID_DOMAIN"),
    INVALID_CATEGORY("INVALID_CATEGORY"),
    DUPLICATE_DOMAIN("DUPLICATE_DOMAIN"),

    /** Already in the other list; the user must remove it there first. */
    IN_OTHER_LIST("IN_OTHER_LIST"),
    LIMIT_REACHED("LIMIT_REACHED"),
}

class UserRuleException(val error: UserRuleError) : IllegalArgumentException(error.code)

/**
 * Custom blocklist / allowlist management with validation:
 * the domain is normalised (scheme/path stripped, case, trailing dot,
 * IDN → punycode, leading `www.` removed), duplicates and cross-list conflicts are reported instead
 * of silently replacing a rule, and the list size is bounded.
 */
class UserRules(
    private val store: RuleStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val maxRules: Int = MAX_USER_RULES,
) {
    fun add(input: String, action: RuleAction, category: Category, includeSubdomains: Boolean = true): Rule {
        val domain = DomainName.parseRuleDomain(input) ?: throw UserRuleException(UserRuleError.INVALID_DOMAIN)
        if (action == RuleAction.BLOCK && !category.isUserAssignable) {
            throw UserRuleException(UserRuleError.INVALID_CATEGORY)
        }
        store.get(domain, RuleSource.USER)?.let { existing ->
            throw UserRuleException(
                if (existing.action == action) UserRuleError.DUPLICATE_DOMAIN else UserRuleError.IN_OTHER_LIST,
            )
        }
        if (store.count(RuleSource.USER) >= maxRules) throw UserRuleException(UserRuleError.LIMIT_REACHED)
        val rule = Rule(
            domain = domain,
            category = if (action == RuleAction.ALLOW) Category.SAFE else category,
            action = action,
            source = RuleSource.USER,
            updatedAt = clock(),
            // Blocks always cover subdomains; allowlist scope is the user's choice.
            includeSubdomains = action == RuleAction.BLOCK || includeSubdomains,
        )
        store.upsert(rule)
        return rule
    }

    fun remove(domain: String, action: RuleAction): Boolean {
        val normalized = DomainName.parseRuleDomain(domain) ?: return false
        val existing = store.get(normalized, RuleSource.USER) ?: return false
        if (existing.action != action) return false
        return store.delete(normalized, RuleSource.USER)
    }

    companion object {
        const val MAX_USER_RULES = 2000
    }
}
