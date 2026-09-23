package com.safeguard.app.engine.lists

import com.safeguard.app.engine.domain.DomainName
import com.safeguard.app.engine.rules.BundledLists
import com.safeguard.app.engine.rules.Category
import com.safeguard.app.engine.rules.HashedDomainList
import com.safeguard.app.engine.rules.NeverBlock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest

object ListFiles {
    val assets = File(System.getProperty("sg.assets") ?: "src/main/assets")
    fun sha256(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
    fun load(path: String) = HashedDomainList.parse(ByteBuffer.wrap(File(assets, path).readBytes()))
    fun samples(): Map<String, List<String>> =
        ListFiles::class.java.getResource("/lists/samples.txt")!!.readText().lines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split('\t') }.groupBy({ it[0] }, { it[1] })
}

class DomainListBuildTest {
    /**
     * Regenerates the assets from downloaded hosts files when SG_LIST_SRC
     * points at a directory with gambling.txt, porn.txt and drugs.txt
     * (The Block List Project, hosts format). Otherwise does nothing.
     */
    @Test fun buildFromSources() {
        val src = System.getenv("SG_LIST_SRC") ?: return
        val report = StringBuilder()
        val samples = StringBuilder("# category<TAB>domain: entries that must be in the shipped lists\n")
        for ((file, category) in listOf("gambling.txt" to Category.GAMBLING, "porn.txt" to Category.SEXUAL, "drugs.txt" to Category.DRUGS)) {
            val raw = File(src, file)
            var skipped = 0
            var guarded = 0
            val domains = LinkedHashSet<String>()
            raw.useLines { lines ->
                for (line in lines) {
                    val t = line.trim()
                    if (t.isEmpty() || t.startsWith("#")) continue
                    val host = t.split(Regex("\\s+")).let { if (it.size >= 2) it[1] else it[0] }
                    val d = DomainName.normalizeQueryName(host)
                    if (d == null || !d.contains('.')) { skipped++; continue }
                    if (!NeverBlock.allows(d)) { guarded++; continue }
                    domains += d
                }
            }
            val bytes = HashedDomainList.build(category, domains)
            val spec = BundledLists.specs.first { it.category == category }
            File(ListFiles.assets, spec.assetPath).apply { parentFile.mkdirs() }.writeBytes(bytes)
            report.append("${category.id}: source=${ListFiles.sha256(raw.readBytes())} entries=${domains.size} skipped=$skipped guarded=$guarded size=${bytes.size} sha256=${ListFiles.sha256(bytes)}\n")
            domains.toList().let { l -> (0 until 10).map { l[it * (l.size / 10)] } }.forEach { samples.append("${category.id}\t$it\n") }
        }
        File("build").mkdirs()
        File("build/lists-report.txt").writeText(report.toString())
        File(System.getenv("SG_SAMPLES_OUT") ?: "build/samples.txt").writeText(samples.toString())
    }

    @Test fun shippedListsMatchTheirPins() {
        for (spec in BundledLists.specs) {
            val bytes = File(ListFiles.assets, spec.assetPath).readBytes()
            assertEquals(spec.assetPath, spec.sizeBytes, bytes.size.toLong())
            assertEquals(spec.assetPath, spec.sha256, ListFiles.sha256(bytes))
            val list = HashedDomainList.parse(ByteBuffer.wrap(bytes))
            assertEquals(spec.category, list.category)
            assertEquals(spec.entries, list.size)
        }
    }

    @Test fun sampledEntriesAreFoundAndCorePlatformsAreNot() {
        val lists = BundledLists.specs.associate { it.category.id to ListFiles.load(it.assetPath) }
        for ((category, domains) in ListFiles.samples()) {
            for (d in domains) assertTrue("$category $d", lists.getValue(category).contains(d))
        }
        for (list in lists.values) {
            for (d in NeverBlock.domains) assertFalse("${list.category} $d", list.contains(d))
            for (d in listOf("wikipedia.org", "example.com", "bbc.co.uk", "aljazeera.net", "gov.sa")) {
                assertFalse("${list.category} $d", list.contains(d))
            }
        }
    }
}
