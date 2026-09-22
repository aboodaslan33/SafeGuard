package com.safeguard.app.protection

import android.content.Context
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.ProtectionPolicy
import com.safeguard.app.engine.rules.UnknownDomainPolicy

/**
 * Native copy of the protection settings.
 *
 * Flutter owns the settings UI, but the VPN must keep working when Flutter
 * isn't running (after a reboot, after the app is swiped away), so every
 * change is mirrored here and the VPN reads only this store.
 */
class ProtectionConfigStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    @Volatile
    private var cached: ProtectionPolicy = read()

    val policy: ProtectionPolicy get() = cached

    /** Whether the user wants protection on (intent, not VPN state). */
    val enabled: Boolean get() = cached.enabled

    @Synchronized
    fun update(enabled: Boolean? = null, categories: Set<Category>? = null): ProtectionPolicy {
        val next = cached.copy(
            enabled = enabled ?: cached.enabled,
            blockedCategories = (categories ?: cached.blockedCategories).filter { it.isFilterable }.toSet(),
        )
        prefs.edit()
            .putBoolean(KEY_ENABLED, next.enabled)
            .putStringSet(KEY_CATEGORIES, next.blockedCategories.map { it.id }.toSet())
            .apply()
        cached = next
        return next
    }

    @Synchronized
    fun setCategory(category: Category, blocked: Boolean): ProtectionPolicy {
        val set = cached.blockedCategories.toMutableSet()
        if (blocked) set += category else set -= category
        return update(categories = set)
    }

    fun clear() {
        prefs.edit().clear().apply()
        cached = read()
    }

    private fun read(): ProtectionPolicy {
        // Secure default before Flutter has ever synced: all categories on,
        // protection off until the user turns it on (VPN needs consent).
        val ids = prefs.getStringSet(KEY_CATEGORIES, null)
        val categories = ids?.mapNotNull(Category::fromId)?.toSet() ?: Category.filterable.toSet()
        return ProtectionPolicy(
            enabled = prefs.getBoolean(KEY_ENABLED, false),
            blockedCategories = categories,
            // Strict Mode is not exposed yet; unknown domains are allowed.
            unknownDomains = UnknownDomainPolicy.ALLOW,
        )
    }

    private companion object {
        const val NAME = "safeguard_protection"
        const val KEY_ENABLED = "enabled"
        const val KEY_CATEGORIES = "blocked_categories"
    }
}
