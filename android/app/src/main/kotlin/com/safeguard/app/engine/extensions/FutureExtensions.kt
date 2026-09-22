package com.safeguard.app.engine.extensions

import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.ProtectionPolicy

/*
 * Extension points for later phases. Interfaces only — none of these are
 * implemented or wired in Phase 2, and nothing here does network I/O.
 *
 * Also see:
 *  - rules.RemoteRuleSource     remote rule-list updates
 *  - rules.DomainClassifier     AI / heuristic domain classification
 *  - search.SearchFilterService search query classification
 */

/** On-device image classification (e.g. a local model). */
interface ImageClassifier {
    fun classify(image: ByteArray): Map<Category, Float>
}

/** Per-app rules (block or restrict specific packages). */
interface AppProtectionPolicy {
    fun isAppBlocked(packageName: String, policy: ProtectionPolicy): Boolean
}

/** Opt-in, end-to-end encrypted sync of settings to a family dashboard. */
interface SettingsSync {
    fun push(policy: ProtectionPolicy)
    fun pull(): ProtectionPolicy?
}
