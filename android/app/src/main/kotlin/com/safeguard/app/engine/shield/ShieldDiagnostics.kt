package com.safeguard.app.engine.shield

import java.util.concurrent.atomic.AtomicLong

/**
 * Live, content-free counters that show where the shield pipeline stops on
 * a real device (service connected? events from the app? frames? model
 * results?). Memory only, reset when the process ends; never logged,
 * stored or sent. Holds package names, labels and rounded scores, never
 * text, queries or images.
 */
class ShieldDiagnostics(private val clock: () -> Long = System::currentTimeMillis) {
    @Volatile var serviceConnected = false
    @Volatile var eventTypesConfigured = 0
    @Volatile var packagesConfigured = -1 // -1: every app ("all apps")

    val events = AtomicLong()
    val eventsFromSupported = AtomicLong()
    @Volatile var lastEventPackage: String? = null
    @Volatile var lastEventAt = 0L
    @Volatile var foreground: String? = null

    val textSnapshots = AtomicLong()
    val textChecks = AtomicLong()
    @Volatile var lastText: String? = null

    val searchFields = AtomicLong()
    val searchChecks = AtomicLong()
    val searchBlocks = AtomicLong()

    val framesReceived = AtomicLong()
    val framesChecked = AtomicLong()
    val framesInactive = AtomicLong()
    val framesNoModel = AtomicLong()
    @Volatile var lastImage: String? = null

    val blocks = AtomicLong()
    @Volatile var lastBlock: String? = null

    fun onEvent(pkg: String, supported: Boolean) {
        events.incrementAndGet()
        if (supported) eventsFromSupported.incrementAndGet()
        lastEventPackage = pkg
        lastEventAt = clock()
    }

    fun onClassified(c: AiClassification) {
        val top = c.scores.maxByOrNull { it.value }
        val summary = if (top == null) c.status.name.lowercase() else "${top.key.id} ${(top.value * 100).toInt()}%"
        if (c.kind == com.safeguard.app.engine.ai.ContentKind.IMAGE) {
            framesChecked.incrementAndGet()
            lastImage = summary
        } else {
            textChecks.incrementAndGet()
            lastText = summary
        }
    }

    fun onBlocked(e: ShieldEvent, action: BlockAction) {
        blocks.incrementAndGet()
        lastBlock = "${e.kind.name.lowercase()} ${e.label.id} ${action.id}"
    }

    /**
     * The first stage that isn't working, as a stable id the UI translates
     * (null = nothing obviously wrong). [supportedInFront]: a supported,
     * enabled app is in front now.
     */
    fun verdict(status: ShieldStatus, captureRunning: Boolean, supportedInFront: Boolean): String? = when {
        !serviceConnected -> "service_not_connected"
        eventTypesConfigured == 0 -> "service_idle"
        eventsFromSupported.get() == 0L -> "no_events"
        !status.textActive && !status.imageActive -> "not_active"
        !captureRunning -> "capture_off"
        supportedInFront && framesReceived.get() == 0L -> "no_frames"
        framesNoModel.get() > 0 && framesChecked.get() == 0L -> "image_model_failed"
        else -> null
    }

    fun toMap(status: ShieldStatus, captureRunning: Boolean, supportedInFront: Boolean): Map<String, Any?> = mapOf(
        "verdict" to verdict(status, captureRunning, supportedInFront),
        "serviceConnected" to serviceConnected,
        "eventTypes" to eventTypesConfigured,
        "packages" to packagesConfigured,
        "events" to events.get(),
        "eventsFromSupported" to eventsFromSupported.get(),
        "lastEventPackage" to lastEventPackage,
        "lastEventAgeS" to if (lastEventAt == 0L) null else (clock() - lastEventAt) / 1000,
        "foreground" to foreground,
        "textSnapshots" to textSnapshots.get(),
        "textChecks" to textChecks.get(),
        "lastText" to lastText,
        "searchFields" to searchFields.get(),
        "searchChecks" to searchChecks.get(),
        "searchBlocks" to searchBlocks.get(),
        "captureRunning" to captureRunning,
        "framesReceived" to framesReceived.get(),
        "framesChecked" to framesChecked.get(),
        "framesInactive" to framesInactive.get(),
        "framesNoModel" to framesNoModel.get(),
        "lastImage" to lastImage,
        "blocks" to blocks.get(),
        "lastBlock" to lastBlock,
    )
}
