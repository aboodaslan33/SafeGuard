package com.safeguard.app.engine.extensions

import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.ProtectionPolicy

/*
 * Extension points for later phases. Interfaces only — none of these are
 * implemented or wired in Phase 2, and nothing here does network I/O.
 *
 * Phase 4 (AI) plugs in here:
 *  - search.SearchClassifier    on-device query model (combine with the
 *                               rule layer via CombinedSearchClassifier)
 *  - rules.DomainClassifier     domain classification for unknown domains
 *  - logging.EventSource.AI     event source already reserved
 * Also: rules.RemoteRuleSource for remote rule-list updates.
 */

/** On-device image classification (e.g. a local model). */
interface ImageClassifier {
    fun classify(image: ByteArray): Map<Category, Float>
}

/** Opt-in, end-to-end encrypted sync of settings to a family dashboard. */
interface SettingsSync {
    fun push(policy: ProtectionPolicy)
    fun pull(): ProtectionPolicy?
}
