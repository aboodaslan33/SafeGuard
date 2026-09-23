package com.safeguard.app.engine.extensions

import com.safeguard.app.engine.rules.ProtectionPolicy

/*
 * Extension points for later phases. Interfaces only; nothing here does
 * network I/O.
 *
 * AI classification (Phase 4) lives in engine/ai (ContentClassifier,
 * ClassifierAdapter, ProtectionDecisionEngine). Still unused hooks:
 *  - rules.DomainClassifier   deliberately not wired to AI (runs on every
 *                             DNS lookup; false positives break sites)
 *  - rules.RemoteRuleSource   remote rule-list updates
 */

/** Opt-in, end-to-end encrypted sync of settings to a family dashboard. */
interface SettingsSync {
    fun push(policy: ProtectionPolicy)
    fun pull(): ProtectionPolicy?
}
