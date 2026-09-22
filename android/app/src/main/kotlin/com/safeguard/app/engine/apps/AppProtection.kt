package com.safeguard.app.engine.apps

/** An app the user asked SafeGuard to protect against (block on open). */
data class ProtectedApp(val packageName: String, val addedAt: Long)

interface ProtectedAppStore {
    fun list(): List<ProtectedApp>
    fun contains(packageName: String): Boolean
    fun add(app: ProtectedApp): Boolean
    fun remove(packageName: String): Boolean
    fun count(): Int
    fun clear()
}

class InMemoryProtectedAppStore : ProtectedAppStore {
    private val apps = LinkedHashMap<String, ProtectedApp>()
    @Synchronized override fun list() = apps.values.sortedBy { it.packageName }
    @Synchronized override fun contains(packageName: String) = packageName in apps
    @Synchronized override fun add(app: ProtectedApp) = apps.putIfAbsent(app.packageName, app) == null
    @Synchronized override fun remove(packageName: String) = apps.remove(packageName) != null
    @Synchronized override fun count() = apps.size
    @Synchronized override fun clear() = apps.clear()
}

/** Why an app can't be added. Codes are sent to Flutter unchanged. */
enum class AppRuleError(val code: String) {
    INVALID_PACKAGE("INVALID_PACKAGE"),
    NOT_INSTALLED("PACKAGE_NOT_INSTALLED"),
    DUPLICATE("DUPLICATE_PACKAGE"),

    /** SafeGuard itself, launcher, Settings, phone/emergency, system UI. */
    NOT_ALLOWED("PACKAGE_NOT_ALLOWED"),
    LIMIT_REACHED("LIMIT_REACHED"),
}

class AppRuleException(val error: AppRuleError) : IllegalArgumentException(error.code)

enum class AppAction { ALLOW, BLOCK_APP }

data class AppDecision(val action: AppAction, val packageName: String, val reason: String)

/**
 * App protection rules.
 *
 * Supported behaviour on Android, and nothing more: when a protected app
 * comes to the foreground, SafeGuard sends the user to the home screen and
 * shows its own "app protected" screen. It cannot see or filter content
 * *inside* any app, and it never protects apps whose blocking would take
 * control of the device away from its owner (see [isNeverProtectable]).
 */
class AppProtection(
    private val store: ProtectedAppStore,
    /** Is this package installed and launchable? (PackageManager on Android.) */
    private val isInstalled: (String) -> Boolean,
    /** Packages that must never be blocked on this device (launchers, dialer…). */
    private val neverProtect: () -> Set<String>,
    private val clock: () -> Long = System::currentTimeMillis,
    private val maxApps: Int = 200,
) {
    fun list(): List<ProtectedApp> = store.list()

    fun add(rawPackage: String): ProtectedApp {
        val pkg = rawPackage.trim()
        if (!isValidPackageName(pkg)) throw AppRuleException(AppRuleError.INVALID_PACKAGE)
        if (isNeverProtectable(pkg)) throw AppRuleException(AppRuleError.NOT_ALLOWED)
        if (store.contains(pkg)) throw AppRuleException(AppRuleError.DUPLICATE)
        if (!isInstalled(pkg)) throw AppRuleException(AppRuleError.NOT_INSTALLED)
        if (store.count() >= maxApps) throw AppRuleException(AppRuleError.LIMIT_REACHED)
        val app = ProtectedApp(pkg, clock())
        store.add(app)
        return app
    }

    fun remove(packageName: String): Boolean = store.remove(packageName.trim())

    fun isNeverProtectable(pkg: String): Boolean =
        pkg in ALWAYS_EXEMPT || pkg in neverProtect()

    /**
     * Decision for a foreground window change. Protection off → ALLOW.
     * Uninstalled-then-reinstalled apps stay protected (the rule is by name).
     */
    fun decide(foregroundPackage: String?, protectionEnabled: Boolean): AppDecision {
        val pkg = foregroundPackage ?: return AppDecision(AppAction.ALLOW, "", "no_package")
        if (!protectionEnabled) return AppDecision(AppAction.ALLOW, pkg, "protection_off")
        if (isNeverProtectable(pkg)) return AppDecision(AppAction.ALLOW, pkg, "exempt")
        if (!store.contains(pkg)) return AppDecision(AppAction.ALLOW, pkg, "not_protected")
        return AppDecision(AppAction.BLOCK_APP, pkg, "protected_app")
    }

    companion object {
        const val SAFEGUARD_PACKAGE = "com.safeguard.app"

        /** Exempt on every device, in addition to the device's launcher/dialer. */
        val ALWAYS_EXEMPT = setOf(
            SAFEGUARD_PACKAGE,
            "android",
            "com.android.systemui",
            "com.android.settings",
            "com.android.phone",
            "com.android.emergency",
            "com.google.android.dialer",
            "com.android.dialer",
            "com.android.server.telecom",
            "com.google.android.permissioncontroller",
            "com.android.permissioncontroller",
            "com.android.packageinstaller",
            "com.google.android.packageinstaller",
        )

        private val PACKAGE = Regex("^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z][a-zA-Z0-9_]*)+$")

        fun isValidPackageName(pkg: String): Boolean = pkg.length <= 255 && PACKAGE.matches(pkg)
    }
}

/** State of SafeGuard's accessibility service, as the UI must present it. */
enum class AccessibilityState(val id: String) {
    /** The device/profile has no accessibility framework or blocks third-party services. */
    UNAVAILABLE("unavailable"),

    /** The user declined SafeGuard's disclosure; SafeGuard won't ask again unprompted. */
    PERMISSION_DENIED("permission_denied"),

    /** Available but not switched on in system settings. */
    DISABLED("disabled"),
    ENABLED("enabled"),
}

object AccessibilityStateResolver {
    /**
     * @param frameworkAvailable AccessibilityManager exists for this user.
     * @param enabledServices value of Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
     *        (colon-separated flattened component names), possibly null.
     * @param ourComponent flattened ComponentName of SafeGuard's service.
     * @param disclosureDeclined the user said "no" to SafeGuard's disclosure.
     */
    fun resolve(
        frameworkAvailable: Boolean,
        enabledServices: String?,
        ourComponent: String,
        disclosureDeclined: Boolean,
    ): AccessibilityState {
        if (!frameworkAvailable) return AccessibilityState.UNAVAILABLE
        val enabled = enabledServices.orEmpty()
            .split(':')
            .any { it.equals(ourComponent, ignoreCase = true) || it.equals(shortForm(ourComponent), ignoreCase = true) }
        return when {
            enabled -> AccessibilityState.ENABLED
            disclosureDeclined -> AccessibilityState.PERMISSION_DENIED
            else -> AccessibilityState.DISABLED
        }
    }

    /** "pkg/pkg.Cls" ↔ "pkg/.Cls" — Android stores either form. */
    private fun shortForm(component: String): String {
        val (pkg, cls) = component.split('/', limit = 2).let { it[0] to it.getOrElse(1) { "" } }
        return if (cls.startsWith("$pkg.")) "$pkg/${cls.removePrefix(pkg)}" else component
    }
}
