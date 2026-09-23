package com.safeguard.app.engine.updates

/** What an update package may contain. Data only: never code. */
enum class UpdateKind(val id: String) {
    DOMAIN_LIST("domain-list"),
    SEARCH_RULES("search-rules"),
    CATEGORY_RULES("category-rules"),
    AI_MODEL("ai-model");

    companion object {
        fun fromId(id: String) = entries.firstOrNull { it.id == id }
    }
}

/**
 * Signed description of one update package.
 *
 * Wire format: UTF-8 `key=value` lines, strictly validated — every key
 * known, none repeated, every value matching its pattern. (No JSON parser
 * in the engine, and a closed format leaves nothing to interpret.)
 *
 * ```
 * schema=1
 * kind=domain-list
 * id=gambling
 * version=42
 * minAppVersionCode=8
 * createdAt=1760000000        (epoch seconds)
 * expiresAt=1790000000
 * format=sgbl/1               (payload format the validator must accept)
 * payloadSize=2741003
 * payloadSha256=<64 hex>
 * ```
 */
data class UpdateManifest(
    val kind: UpdateKind,
    val id: String,
    val version: Long,
    val minAppVersionCode: Int,
    val createdAtSec: Long,
    val expiresAtSec: Long,
    val format: String,
    val payloadSize: Long,
    val payloadSha256: String,
) {
    companion object {
        const val SCHEMA = 1
        const val MAX_MANIFEST_BYTES = 4096

        private val patterns = mapOf(
            "schema" to Regex("^[0-9]{1,3}$"),
            "kind" to Regex("^[a-z-]{1,32}$"),
            "id" to Regex("^[a-z0-9_]{1,32}$"),
            "version" to Regex("^[0-9]{1,12}$"),
            "minAppVersionCode" to Regex("^[0-9]{1,9}$"),
            "createdAt" to Regex("^[0-9]{1,12}$"),
            "expiresAt" to Regex("^[0-9]{1,12}$"),
            "format" to Regex("^[a-z_]{1,16}/[0-9]{1,3}$"),
            "payloadSize" to Regex("^[0-9]{1,12}$"),
            "payloadSha256" to Regex("^[0-9a-f]{64}$"),
        )

        /** Throws [UpdateRejected] (SCHEMA) on anything unexpected. */
        fun parse(bytes: ByteArray): UpdateManifest {
            fun bad(why: String): Nothing = throw UpdateRejected(Rejection.SCHEMA, why)
            if (bytes.isEmpty() || bytes.size > MAX_MANIFEST_BYTES) bad("size")
            val text = try {
                Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            } catch (e: java.nio.charset.CharacterCodingException) {
                bad("encoding")
            }
            val values = HashMap<String, String>()
            for (raw in text.split('\n')) {
                val line = raw.trimEnd('\r')
                if (line.isEmpty()) continue
                val eq = line.indexOf('=')
                if (eq <= 0) bad("line")
                val key = line.substring(0, eq)
                val value = line.substring(eq + 1)
                val pattern = patterns[key] ?: bad("unknown key")
                if (!pattern.matches(value)) bad("value of $key")
                if (values.put(key, value) != null) bad("duplicate $key")
            }
            if (values.keys != patterns.keys) bad("missing keys")
            if (values.getValue("schema").toInt() != SCHEMA) bad("schema version")
            val kind = UpdateKind.fromId(values.getValue("kind")) ?: bad("kind")
            val created = values.getValue("createdAt").toLong()
            val expires = values.getValue("expiresAt").toLong()
            if (expires <= created) bad("expiry before creation")
            val size = values.getValue("payloadSize").toLong()
            if (size <= 0) bad("empty payload")
            return UpdateManifest(
                kind = kind,
                id = values.getValue("id"),
                version = values.getValue("version").toLong(),
                minAppVersionCode = values.getValue("minAppVersionCode").toInt(),
                createdAtSec = created,
                expiresAtSec = expires,
                format = values.getValue("format"),
                payloadSize = size,
                payloadSha256 = values.getValue("payloadSha256"),
            )
        }
    }
}

enum class Rejection {
    SIGNATURE, SCHEMA, UNKNOWN_PACKAGE, DOWNGRADE, DUPLICATE, INCOMPATIBLE,
    EXPIRED, TOO_LARGE, CHECKSUM, INVALID_PAYLOAD, STORAGE
}

class UpdateRejected(val reason: Rejection, detail: String) : Exception("${reason.name}: $detail")
