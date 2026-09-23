package com.safeguard.app.engine.shield

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Static checks over the shipped sources that keep the AI Content Shield's
 * privacy promises true: no screenshots, overlays, storage, logging or
 * network in the shield path, and events only from the supported apps.
 */
class ShieldSourceAuditTest {

    private val root: File = (
        listOfNotNull(System.getProperty("sg.assets")?.let { File(it) }, File("").absoluteFile)
            .flatMap { generateSequence(it) { f -> f.parentFile }.toList() }
            .firstOrNull { File(it, "android/app/src/main").isDirectory && File(it, "lib").isDirectory }
        ) ?: error("project root not found")

    private fun file(path: String) = File(root, path).also { assertTrue("missing $path", it.isFile) }.readText()

    private val main = "android/app/src/main"
    private val service get() = file("$main/kotlin/com/safeguard/app/shield/ContentShieldService.kt")
    private val shieldEngine get() = File(root, "$main/kotlin/com/safeguard/app/engine/shield").listFiles()!!.joinToString("\n") { it.readText() }

    @Test fun accessibilityConfigListsExactlyTheSupportedApps() {
        val xml = file("$main/res/xml/content_shield_config.xml")
        val packages = Regex("android:packageNames=\"([^\"]+)\"").find(xml)!!.groupValues[1].split(',')
        assertEquals(SupportedApps.allPackages, packages.sorted())
        assertTrue(xml.contains("android:canRetrieveWindowContent=\"true\""))
        assertFalse("no screenshots via accessibility", xml.contains("canTakeScreenshot"))
        assertFalse(file("$main/res/xml/accessibility_service_config.xml").contains("canRetrieveWindowContent=\"true\""))
    }

    @Test fun manifestAddsNoCapturingOrOverlayPermission() {
        val manifest = file("$main/AndroidManifest.xml")
        val permissions = Regex("<uses-permission[^>]*android:name=\"([^\"]+)\"").findAll(manifest).map { it.groupValues[1] }.toSet()
        assertEquals(
            setOf(
                "android.permission.INTERNET",
                "android.permission.ACCESS_NETWORK_STATE",
                "android.permission.RECEIVE_BOOT_COMPLETED",
                "android.permission.POST_NOTIFICATIONS",
            ),
            permissions,
        )
        assertFalse("no screen-capture service type", manifest.contains("foregroundServiceType=\"mediaProjection\""))
        val entry = manifest.substringAfter(".shield.ContentShieldService").substringBefore("</service>")
        assertTrue(entry.contains("android.permission.BIND_ACCESSIBILITY_SERVICE"))
        assertTrue(entry.contains("android:exported=\"false\""))
    }

    @Test fun shieldPathNeverLogsStoresSendsOrCapturesContent() {
        // Code only: comments may describe what is deliberately not done.
        val code = (service + "\n" + shieldEngine).lines()
            .map { it.substringBefore("//").trim() }
            .filterNot { it.startsWith("*") || it.startsWith("/*") }
            .joinToString("\n")
        val forbidden = listOf(
            "Log.", "println(", "FileOutputStream", "openFileOutput", "writeText(", "SharedPreferences", "getSharedPreferences",
            "HttpURLConnection", "URL(", "Socket(", "takeScreenshot", "MediaProjection", "TYPE_APPLICATION_OVERLAY",
            "TYPE_ACCESSIBILITY_OVERLAY", "addView(", "Bitmap.compress",
        )
        for (f in forbidden) assertFalse("shield code must not use $f", code.contains(f))
    }

    @Test fun serviceNeverReceivesEventsFromEveryApp() {
        // A null packageNames list would mean "all apps".
        assertTrue(service.contains("ifEmpty { SupportedApps.allPackages }"))
        assertFalse(service.contains("packageNames = null"))
    }
}
