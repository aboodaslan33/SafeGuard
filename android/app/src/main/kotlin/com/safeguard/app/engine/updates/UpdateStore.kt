package com.safeguard.app.engine.updates

import java.io.File
import java.security.MessageDigest

/** Checks that a payload is really of the declared format (parses it fully). */
fun interface PayloadValidator {
    /** Throws on invalid content. */
    fun validate(manifest: UpdateManifest, payload: ByteArray)
}

/** An activated, verified package ready to load. */
data class ActiveUpdate(val manifest: UpdateManifest, val payload: File)

/**
 * Local store for verified update packages (rules, lists, AI models).
 *
 * Layout: `root/<kind>/<id>/<version>/{manifest,manifest.sig,payload}` and
 * `root/<kind>/<id>/active` (the active version number).
 *
 * Invariants:
 *  - Nothing becomes active before signature, schema, compatibility,
 *    version, expiry, size, checksum *and* full payload parsing pass.
 *  - Activation is a staged write + directory rename + atomic pointer
 *    replace; a failure at any step leaves the previous state intact.
 *  - At most [keepVersions] versions per package; older ones are deleted.
 *  - Readers get the active package only while it is unexpired; otherwise
 *    the newest unexpired previous version, otherwise null — the caller
 *    then uses the copy bundled in the APK (offline fallback).
 *
 * No network code: a transport (HTTPS, pinned) would only hand bytes to
 * [install]. None ships while there is no update server.
 */
class UpdateStore(
    private val root: File,
    private val verifier: UpdateSignatureVerifier,
    private val appVersionCode: Int,
    /** Accepted `format` per kind, e.g. DOMAIN_LIST → {"sgbl/1"}. */
    private val formats: Map<UpdateKind, Set<String>>,
    private val validators: Map<UpdateKind, PayloadValidator>,
    /** Per-kind payload cap in bytes. */
    private val maxBytes: Map<UpdateKind, Long>,
    private val allowedIds: Map<UpdateKind, Set<String>>,
    private val nowSec: () -> Long = { System.currentTimeMillis() / 1000 },
    private val keepVersions: Int = 2,
) {
    @Synchronized
    fun install(manifestBytes: ByteArray, signature: ByteArray, payload: ByteArray): UpdateManifest {
        if (!verifier.isValid(manifestBytes, signature)) throw UpdateRejected(Rejection.SIGNATURE, "bad signature")
        val m = UpdateManifest.parse(manifestBytes)
        if (m.id !in allowedIds[m.kind].orEmpty()) throw UpdateRejected(Rejection.UNKNOWN_PACKAGE, m.id)
        if (m.format !in formats[m.kind].orEmpty()) throw UpdateRejected(Rejection.INCOMPATIBLE, m.format)
        if (m.minAppVersionCode > appVersionCode) throw UpdateRejected(Rejection.INCOMPATIBLE, "app too old")
        if (nowSec() >= m.expiresAtSec) throw UpdateRejected(Rejection.EXPIRED, "expired")
        val dir = packageDir(m.kind, m.id)
        if (File(dir, m.version.toString()).exists()) throw UpdateRejected(Rejection.DUPLICATE, "v${m.version}")
        val newest = versions(dir).maxOrNull()
        if (newest != null && m.version <= newest) throw UpdateRejected(Rejection.DOWNGRADE, "v${m.version} ≤ v$newest")
        if (m.payloadSize > (maxBytes[m.kind] ?: 0)) throw UpdateRejected(Rejection.TOO_LARGE, "cap")
        if (payload.size.toLong() != m.payloadSize) throw UpdateRejected(Rejection.CHECKSUM, "size")
        if (sha256(payload) != m.payloadSha256) throw UpdateRejected(Rejection.CHECKSUM, "sha256")
        try {
            validators.getValue(m.kind).validate(m, payload)
        } catch (e: UpdateRejected) {
            throw e
        } catch (e: Exception) {
            throw UpdateRejected(Rejection.INVALID_PAYLOAD, e.javaClass.simpleName)
        }

        // Stage completely, then publish with renames.
        val staging = File(dir, ".staging-${m.version}")
        try {
            staging.deleteRecursively()
            if (!staging.mkdirs()) throw UpdateRejected(Rejection.STORAGE, "mkdir")
            File(staging, "manifest").writeBytes(manifestBytes)
            File(staging, "manifest.sig").writeBytes(signature)
            File(staging, "payload").writeBytes(payload)
            val target = File(dir, m.version.toString())
            if (!staging.renameTo(target)) throw UpdateRejected(Rejection.STORAGE, "rename")
            setActive(dir, m.version)
        } catch (e: java.io.IOException) {
            throw UpdateRejected(Rejection.STORAGE, e.javaClass.simpleName)
        } finally {
            staging.deleteRecursively()
        }
        cleanup(dir)
        return m
    }

    /** The package to use now, or null → use the APK's bundled copy. */
    @Synchronized
    fun active(kind: UpdateKind, id: String): ActiveUpdate? {
        val dir = packageDir(kind, id)
        val pointer = readActive(dir)
        val candidates = versions(dir).sortedDescending().let { all ->
            // Active first, then older ones (never newer than active: a
            // rolled-back version stays rolled back).
            if (pointer == null) all else listOf(pointer) + all.filter { it < pointer }
        }
        for (v in candidates) {
            val loaded = load(dir, v) ?: continue
            if (nowSec() < loaded.manifest.expiresAtSec) return loaded
        }
        return null
    }

    /** Switches to the previous installed version; false if there is none. */
    @Synchronized
    fun rollback(kind: UpdateKind, id: String): Boolean {
        val dir = packageDir(kind, id)
        val current = readActive(dir) ?: return false
        val previous = versions(dir).filter { it < current }.maxOrNull() ?: return false
        setActive(dir, previous)
        return true
    }

    /** Removes every installed package of this kind/id (back to the APK copy). */
    @Synchronized
    fun reset(kind: UpdateKind, id: String) {
        packageDir(kind, id).deleteRecursively()
    }

    // ---- internals ------------------------------------------------------

    private fun packageDir(kind: UpdateKind, id: String) = File(File(root, kind.id), id)

    private fun versions(dir: File): List<Long> =
        dir.listFiles()?.filter { it.isDirectory }?.mapNotNull { it.name.toLongOrNull() }.orEmpty()

    private fun readActive(dir: File): Long? =
        File(dir, "active").takeIf { it.isFile }?.readText()?.trim()?.toLongOrNull()

    /** Write-then-rename: the pointer is never half-written. */
    private fun setActive(dir: File, version: Long) {
        val tmp = File(dir, "active.tmp")
        tmp.writeText(version.toString())
        val active = File(dir, "active")
        if (!tmp.renameTo(active)) {
            // Some filesystems don't replace on rename.
            active.delete()
            if (!tmp.renameTo(active)) throw UpdateRejected(Rejection.STORAGE, "pointer")
        }
    }

    /** Re-verifies everything on load: a file modified on disk is ignored. */
    private fun load(dir: File, version: Long): ActiveUpdate? {
        val vdir = File(dir, version.toString())
        return try {
            val manifestBytes = File(vdir, "manifest").readBytes()
            val sig = File(vdir, "manifest.sig").readBytes()
            if (!verifier.isValid(manifestBytes, sig)) return null
            val m = UpdateManifest.parse(manifestBytes)
            val payload = File(vdir, "payload")
            if (payload.length() != m.payloadSize) return null
            if (sha256(payload.readBytes()) != m.payloadSha256) return null
            ActiveUpdate(m, payload)
        } catch (e: Exception) {
            null
        }
    }

    private fun cleanup(dir: File) {
        val active = readActive(dir)
        val keep = versions(dir).sortedDescending().take(keepVersions).toMutableSet()
        active?.let { keep += it }
        for (v in versions(dir)) if (v !in keep) File(dir, v.toString()).deleteRecursively()
    }

    private fun sha256(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
