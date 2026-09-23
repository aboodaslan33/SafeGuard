package com.safeguard.app.engine.updates

import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.HashedDomainList
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class UpdateStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun keyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()

    private val publisher = keyPair()
    private var now = 1_800_000_000L

    private fun sign(bytes: ByteArray, kp: KeyPair = publisher) = Signature.getInstance("SHA256withECDSA").run {
        initSign(kp.private)
        update(bytes)
        sign()
    }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    private fun list(vararg domains: String) = HashedDomainList.build(Category.GAMBLING, domains.toList())

    private fun manifest(
        payload: ByteArray,
        version: Long,
        id: String = "gambling",
        expires: Long = now + 86_400,
        format: String = "sgbl/1",
        minApp: Int = 1,
        extra: String = "",
    ) = """
        schema=1
        kind=domain-list
        id=$id
        version=$version
        minAppVersionCode=$minApp
        createdAt=${now - 10}
        expiresAt=$expires
        format=$format
        payloadSize=${payload.size}
        payloadSha256=${sha(payload)}
    """.trimIndent().plus(extra).toByteArray()

    private fun store(root: java.io.File = tmp.root) = UpdateStore(
        root = root,
        verifier = UpdateSignatureVerifier(listOf(publisher.public.encoded)),
        appVersionCode = 8,
        formats = mapOf(UpdateKind.DOMAIN_LIST to setOf("sgbl/1")),
        validators = mapOf(UpdateKind.DOMAIN_LIST to UpdateValidators.domainList),
        maxBytes = mapOf(UpdateKind.DOMAIN_LIST to 1_000_000L),
        allowedIds = mapOf(UpdateKind.DOMAIN_LIST to setOf("gambling", "drugs")),
        nowSec = { now },
    )

    private fun expectRejected(reason: Rejection, block: () -> Unit) {
        try {
            block()
            fail("expected $reason")
        } catch (e: UpdateRejected) {
            assertEquals(e.message, reason, e.reason)
        }
    }

    private fun install(s: UpdateStore, payload: ByteArray, version: Long, m: ByteArray = manifest(payload, version)) =
        s.install(m, sign(m), payload)

    @Test fun validPackageInstallsAndActivates() {
        val s = store()
        val p = list("casino.test", "bet.test")
        install(s, p, 1)
        val active = s.active(UpdateKind.DOMAIN_LIST, "gambling")!!
        assertEquals(1L, active.manifest.version)
        assertArrayEquals(p, active.payload.readBytes())
    }

    @Test fun nothingInstalledMeansApkFallback() {
        assertNull(store().active(UpdateKind.DOMAIN_LIST, "gambling"))
    }

    @Test fun signatureMustComeFromAPinnedKey() {
        val s = store()
        val p = list("a.test")
        val m = manifest(p, 1)
        expectRejected(Rejection.SIGNATURE) { s.install(m, sign(m, keyPair()), p) }
        expectRejected(Rejection.SIGNATURE) { s.install(m, byteArrayOf(1, 2, 3), p) }
        // Manifest changed after signing.
        val sig = sign(m)
        val tampered = manifest(p, 2)
        expectRejected(Rejection.SIGNATURE) { s.install(tampered, sig, p) }
        assertNull(s.active(UpdateKind.DOMAIN_LIST, "gambling"))
    }

    @Test fun keyRotationAcceptsEitherPinnedKey() {
        val next = keyPair()
        val s = UpdateStore(
            tmp.root, UpdateSignatureVerifier(listOf(publisher.public.encoded, next.public.encoded)), 8,
            mapOf(UpdateKind.DOMAIN_LIST to setOf("sgbl/1")), mapOf(UpdateKind.DOMAIN_LIST to UpdateValidators.domainList),
            mapOf(UpdateKind.DOMAIN_LIST to 1_000_000L), mapOf(UpdateKind.DOMAIN_LIST to setOf("gambling")), { now },
        )
        val p = list("a.test")
        val m = manifest(p, 1)
        s.install(m, sign(m, next), p)
        assertEquals(1L, s.active(UpdateKind.DOMAIN_LIST, "gambling")!!.manifest.version)
    }

    @Test fun payloadMustMatchSignedChecksum() {
        val s = store()
        val p = list("a.test")
        val m = manifest(p, 1)
        val other = list("b.test")
        expectRejected(Rejection.CHECKSUM) { s.install(m, sign(m), other) }
    }

    @Test fun corruptedPayloadRejectedEvenWithMatchingChecksum() {
        val s = store()
        val garbage = ByteArray(64) { 7 }
        expectRejected(Rejection.INVALID_PAYLOAD) { install(s, garbage, 1) }
        // A list for another category under the "gambling" id.
        val drugs = HashedDomainList.build(Category.DRUGS, listOf("x.test"))
        expectRejected(Rejection.INVALID_PAYLOAD) { install(s, drugs, 1) }
        assertNull(s.active(UpdateKind.DOMAIN_LIST, "gambling"))
    }

    @Test fun schemaIsStrict() {
        val s = store()
        val p = list("a.test")
        expectRejected(Rejection.SCHEMA) { install(s, p, 1, manifest(p, 1, extra = "\nscript=rm -rf /")) }
        expectRejected(Rejection.SCHEMA) { install(s, p, 1, manifest(p, 1, extra = "\nversion=2")) }
        val noKind = manifest(p, 1).toString(Charsets.UTF_8).replace("kind=domain-list\n", "").toByteArray()
        expectRejected(Rejection.SCHEMA) { install(s, p, 1, noKind) }
        val badHash = manifest(p, 1).toString(Charsets.UTF_8).replace(Regex("payloadSha256=.*"), "payloadSha256=zz").toByteArray()
        expectRejected(Rejection.SCHEMA) { install(s, p, 1, badHash) }
    }

    @Test fun versionsOnlyMoveForward() {
        val s = store()
        install(s, list("a.test"), 5)
        expectRejected(Rejection.DUPLICATE) { install(s, list("a.test"), 5) }
        expectRejected(Rejection.DOWNGRADE) { install(s, list("b.test"), 4) }
        assertEquals(5L, s.active(UpdateKind.DOMAIN_LIST, "gambling")!!.manifest.version)
    }

    @Test fun compatibilityAndUnknownPackages() {
        val s = store()
        val p = list("a.test")
        expectRejected(Rejection.INCOMPATIBLE) { install(s, p, 1, manifest(p, 1, minApp = 9)) }
        expectRejected(Rejection.INCOMPATIBLE) { install(s, p, 1, manifest(p, 1, format = "sgbl/2")) }
        expectRejected(Rejection.UNKNOWN_PACKAGE) { install(s, p, 1, manifest(p, 1, id = "violence")) }
    }

    @Test fun expiredPackagesAreRejectedAndStopBeingUsed() {
        val s = store()
        expectRejected(Rejection.EXPIRED) { install(s, list("a.test"), 1, manifest(list("a.test"), 1, expires = now)) }
        install(s, list("a.test"), 1, manifest(list("a.test"), 1, expires = now + 100))
        install(s, list("b.test"), 2, manifest(list("b.test"), 2, expires = now + 50))
        assertEquals(2L, s.active(UpdateKind.DOMAIN_LIST, "gambling")!!.manifest.version)
        now += 60 // v2 expired → previous valid version
        assertEquals(1L, s.active(UpdateKind.DOMAIN_LIST, "gambling")!!.manifest.version)
        now += 60 // all expired → APK copy
        assertNull(s.active(UpdateKind.DOMAIN_LIST, "gambling"))
    }

    @Test fun rollbackAndCleanupKeepTwoVersions() {
        val s = store()
        install(s, list("a.test"), 1)
        install(s, list("b.test"), 2)
        install(s, list("c.test"), 3)
        val dir = java.io.File(tmp.root, "domain-list/gambling")
        assertEquals(setOf("2", "3"), dir.listFiles()!!.filter { it.isDirectory }.map { it.name }.toSet())
        assertTrue(s.rollback(UpdateKind.DOMAIN_LIST, "gambling"))
        assertEquals(2L, s.active(UpdateKind.DOMAIN_LIST, "gambling")!!.manifest.version)
        assertFalse(s.rollback(UpdateKind.DOMAIN_LIST, "gambling")) // nothing older kept
        s.reset(UpdateKind.DOMAIN_LIST, "gambling")
        assertNull(s.active(UpdateKind.DOMAIN_LIST, "gambling"))
    }

    @Test fun oversizedPackagesRejected() {
        val s = UpdateStore(
            tmp.root, UpdateSignatureVerifier(listOf(publisher.public.encoded)), 8,
            mapOf(UpdateKind.DOMAIN_LIST to setOf("sgbl/1")), mapOf(UpdateKind.DOMAIN_LIST to UpdateValidators.domainList),
            mapOf(UpdateKind.DOMAIN_LIST to 10L), mapOf(UpdateKind.DOMAIN_LIST to setOf("gambling")), { now },
        )
        expectRejected(Rejection.TOO_LARGE) { install(s, list("a.test"), 1) }
    }

    @Test fun fileTamperedOnDiskIsIgnoredAtLoad() {
        val s = store()
        install(s, list("a.test"), 1)
        install(s, list("b.test"), 2)
        java.io.File(tmp.root, "domain-list/gambling/2/payload").writeBytes(list("evil.test"))
        // v2 fails re-verification → previous valid version is used.
        assertEquals(1L, s.active(UpdateKind.DOMAIN_LIST, "gambling")!!.manifest.version)
    }

    @Test fun failedInstallLeavesActiveVersionUntouched() {
        val s = store()
        install(s, list("a.test"), 1)
        expectRejected(Rejection.INVALID_PAYLOAD) { install(s, ByteArray(40) { 1 }, 2) }
        assertEquals(1L, s.active(UpdateKind.DOMAIN_LIST, "gambling")!!.manifest.version)
        val staging = java.io.File(tmp.root, "domain-list/gambling").listFiles()!!.filter { it.name.startsWith(".staging") }
        assertTrue(staging.isEmpty())
    }

    @Test fun aiModelValidatorRunsProbeBeforeActivation() {
        val bytes = ByteArray(10)
        val v = UpdateValidators.aiModel { true }
        try {
            v.validate(UpdateManifest.parse(manifest(bytes, 1)).copy(kind = UpdateKind.AI_MODEL), bytes)
            fail("garbage model must not parse")
        } catch (e: Exception) {
            // expected: TextModel.parse rejects it
        }
    }
}
