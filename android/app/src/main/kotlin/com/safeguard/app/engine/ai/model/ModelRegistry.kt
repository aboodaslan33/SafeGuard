package com.safeguard.app.engine.ai.model

import com.safeguard.app.engine.ai.ContentKind
import java.io.InputStream
import java.security.MessageDigest

/**
 * A model SafeGuard is allowed to load. The list is compiled into the app
 * ([BuiltInModels]); a file is used only if its size and SHA-256 match.
 * There is no way to load a model from storage, a URL or user input.
 */
data class ModelSpec(
    val id: String,
    val version: Int,
    val kind: ContentKind,
    /** Path inside the APK's assets. */
    val assetPath: String,
    val sizeBytes: Long,
    /** Lowercase hex SHA-256 of the file. */
    val sha256: String,
    val license: String,
    /** Where the weights and training data come from. */
    val provenance: String,
)

object BuiltInModels {
    /**
     * On-device text model trained in this repository from a seed set
     * written for SafeGuard (android/app/src/test/resources/ai/). Rebuilt
     * and compared byte-for-byte by `TextModelBuildTest`.
     */
    val TEXT_V1 = ModelSpec(
        id = "sg-text-1",
        version = 1,
        kind = ContentKind.TEXT,
        assetPath = "models/sg_text_v1.bin",
        sizeBytes = 197_713,
        sha256 = "59fdfef5a1110e9b917b7e142a75b6562681b33f46337941c03855e3ba7304c1",
        license = "Original work of the SafeGuard project, under the repository's license (no third-party weights or data)",
        provenance = "Logistic regression trained on SafeGuard's own seed phrases (EN/AR)",
    )

    /** No image model is bundled in this version (see docs/PHASE_4_AI.md §License). */
    val all: List<ModelSpec> = listOf(TEXT_V1)

    fun forKind(kind: ContentKind): ModelSpec? = all.firstOrNull { it.kind == kind }
}

class ModelIntegrityException(message: String) : Exception(message)

/**
 * Reads a pinned model file and verifies it before anything parses it.
 * [open] returns the asset stream (Android: `AssetManager.open`), or null.
 */
class ModelLoader(private val open: (String) -> InputStream?) {

    fun load(spec: ModelSpec): ByteArray {
        require(spec in BuiltInModels.all) { "model not in the built-in manifest" }
        require(spec.sizeBytes in 1..MAX_MODEL_BYTES) { "model too large" }
        val stream = open(spec.assetPath) ?: throw ModelIntegrityException("missing")
        val bytes = stream.use { readBounded(it, spec.sizeBytes.toInt()) }
            ?: throw ModelIntegrityException("size mismatch")
        if (bytes.size.toLong() != spec.sizeBytes) throw ModelIntegrityException("size mismatch")
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        if (!MessageDigest.isEqual(digest, hexToBytes(spec.sha256))) {
            throw ModelIntegrityException("checksum mismatch")
        }
        return bytes
    }

    companion object {
        const val MAX_MODEL_BYTES = 64L * 1024 * 1024

        fun sha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

        /** Reads exactly up to [expected] bytes; null if the stream is longer. */
        private fun readBounded(input: InputStream, expected: Int): ByteArray? {
            val out = ByteArray(expected)
            var read = 0
            while (read < expected) {
                val n = input.read(out, read, expected - read)
                if (n < 0) return out.copyOf(read)
                read += n
            }
            return if (input.read() == -1) out else null
        }

        private fun hexToBytes(hex: String): ByteArray {
            require(hex.length == 64) { "bad sha256" }
            return ByteArray(32) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        }
    }
}
