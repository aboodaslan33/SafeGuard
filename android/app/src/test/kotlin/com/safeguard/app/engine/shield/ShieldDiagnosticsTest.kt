package com.safeguard.app.engine.shield

import com.safeguard.app.engine.ai.ContentKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ShieldDiagnosticsTest {
    private val active = ShieldStatus(ShieldState.ACTIVE, emptyList(), textActive = true, imageActive = true)

    @Test fun verdictNamesTheFirstStageThatIsntWorking() {
        val d = ShieldDiagnostics(clock = { 1_000 })
        assertEquals("service_not_connected", d.verdict(active, captureRunning = true, supportedInFront = true))
        d.serviceConnected = true
        assertEquals("service_idle", d.verdict(active, true, true))
        d.eventTypesConfigured = 1
        assertEquals("no_events", d.verdict(active, true, true))
        d.onEvent("com.instagram.android", supported = true)
        assertEquals("capture_off", d.verdict(active, captureRunning = false, supportedInFront = true))
        assertEquals("no_frames", d.verdict(active, true, true))
        assertNull("not in a supported app: no frames expected", d.verdict(active, true, supportedInFront = false))
        d.framesReceived.incrementAndGet()
        d.framesNoModel.incrementAndGet()
        assertEquals("image_model_failed", d.verdict(active, true, true))
        d.onClassified(AiClassification(AiLabel.SAFE, 0.8, "m@1", ContentKind.IMAGE, mapOf(AiLabel.SAFE to 0.8, AiLabel.SEXUAL to 0.2)))
        assertNull(d.verdict(active, true, true))
        assertEquals("safe 80%", d.lastImage)
    }

    @Test fun mapHoldsCountersOnly() {
        val d = ShieldDiagnostics(clock = { 5_000 })
        d.onEvent("com.facebook.katana", supported = true)
        val m = d.toMap(active, captureRunning = false, supportedInFront = false)
        assertEquals(1L, m["eventsFromSupported"])
        assertEquals("com.facebook.katana", m["lastEventPackage"])
        assertEquals(0L, m["lastEventAgeS"])
    }
}
