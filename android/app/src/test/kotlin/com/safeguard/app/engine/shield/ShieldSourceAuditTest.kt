package com.safeguard.app.engine.shield

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Static checks over the shipped sources that keep the AI Content Shield's
 * privacy promises true: no screenshots, storage, logging or network in
 * the shield path, only SafeGuard's own accessibility-overlay cover, and
 * events only from the supported apps.
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

    @Test fun manifestPermissionsAreExactlyTheDeclaredOnes() {
        val manifest = file("$main/AndroidManifest.xml")
        val permissions = Regex("<uses-permission[^>]*android:name=\"([^\"]+)\"").findAll(manifest).map { it.groupValues[1] }.toSet()
        assertEquals(
            setOf(
                "android.permission.INTERNET",
                "android.permission.ACCESS_NETWORK_STATE",
                "android.permission.RECEIVE_BOOT_COMPLETED",
                "android.permission.POST_NOTIFICATIONS",
                // Screen capture for image checks, only after Android's consent dialog.
                "android.permission.FOREGROUND_SERVICE",
                "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
            ),
            permissions,
        )
        val capture = manifest.substringAfter(".shield.ScreenCaptureService").substringBefore("/>")
        assertTrue(capture.contains("android:foregroundServiceType=\"mediaProjection\""))
        assertTrue(capture.contains("android:exported=\"false\""))
        assertEquals("only one media-projection service", 1, Regex("mediaProjection\"").findAll(manifest).count())
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
            "TYPE_ACCESSIBILITY_OVERLAY", "addView(", "Bitmap.compress", "SYSTEM_ALERT_WINDOW", "GLOBAL_ACTION_HOME",
        )
        for (f in forbidden) assertFalse("shield code must not use $f", code.contains(f))
        // The only text written into an app is an empty string (clearing a blocked search).
        assertEquals(1, Regex("ACTION_SET_TEXT").findAll(code).count())
        assertTrue(code.contains("ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, \"\")"))
        // An editable field is read only after it is recognised as a search box.
        assertTrue(code.contains("if (!SearchFieldDetector.isSearchField("))
    }

    @Test fun coverIsOnlyAnAccessibilityOverlayThatReadsNothing() {
        val code = file("$main/kotlin/com/safeguard/app/shield/ShieldCover.kt").lines()
            .map { it.substringBefore("//").trim() }
            .filterNot { it.startsWith("*") || it.startsWith("/*") }
            .joinToString("\n")
        assertTrue(code.contains("TYPE_ACCESSIBILITY_OVERLAY"))
        for (f in listOf(
            "TYPE_APPLICATION_OVERLAY", "SYSTEM_ALERT_WINDOW", "AccessibilityNodeInfo", "rootInActiveWindow", "MediaProjection",
            "takeScreenshot", "Log.", "SharedPreferences", "HttpURLConnection", "Socket(", "GLOBAL_ACTION_HOME",
        )) {
            assertFalse("cover must not use $f", code.contains(f))
        }
        assertFalse(file("$main/AndroidManifest.xml").contains("SYSTEM_ALERT_WINDOW"))
    }

    @Test fun screenCaptureNeverSavesEncodesLogsOrSendsFrames() {
        val code = file("$main/kotlin/com/safeguard/app/shield/ScreenCaptureService.kt").lines()
            .map { it.substringBefore("//").trim() }
            .filterNot { it.startsWith("*") || it.startsWith("/*") }
            .joinToString("\n")
        for (f in listOf("Log.", "println(", "Bitmap", "compress(", "FileOutputStream", "openFileOutput", "writeBytes(", "HttpURLConnection", "Socket(", "MediaRecorder", "SharedPreferences")) {
            assertFalse("capture code must not use $f", code.contains(f))
        }
        // Frames are released right after classification.
        assertTrue(code.contains("image.close()"))
        // Capture only through the consent intent.
        assertTrue(code.contains("createScreenCaptureIntent"))
    }

    @Test fun serviceReceivesEventsFromEveryAppOnlyWithAllAppsOn() {
        // A null packageNames list means "all apps": only behind the user's switch.
        assertTrue(service.contains("ifEmpty { SupportedApps.allPackages }"))
        assertTrue(service.contains("info.packageNames = if (manager.config.shieldSettings.watchesAllApps) null else"))
        assertFalse(service.contains("packageNames = null"))
        // Text is only ever read in supported apps.
        assertTrue(service.contains("if (!supported || !engine.isActiveFor(pkg))"))
    }
}
