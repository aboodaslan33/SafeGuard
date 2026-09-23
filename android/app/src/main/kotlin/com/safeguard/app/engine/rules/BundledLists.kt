package com.safeguard.app.engine.rules

/** One bundled list asset, pinned like the AI model (see docs/LISTS.md). */
data class ListSpec(
    val category: Category,
    val assetPath: String,
    val entries: Int,
    val sizeBytes: Long,
    val sha256: String,
)

/**
 * Category lists shipped in the APK, built from The Block List Project
 * (github.com/blocklistproject/Lists; repository licence: Unlicense,
 * file headers: MIT) by `DomainListBuildTest`. Exact core platforms are
 * removed at build time (see [NeverBlock]).
 */
object BundledLists {
    const val SOURCE = "The Block List Project, snapshot of 2026-07 (gambling, porn, drugs)"

    val specs: List<ListSpec> = listOf(
        ListSpec(Category.GAMBLING, "lists/gambling.sgbl", 342_623, 2_741_003, "edbcb7aed9eceb98014493dbe0e2c2c99e5fd67cbc7e4b50b848225fb2f00f9d"),
        ListSpec(Category.SEXUAL, "lists/sexual.sgbl", 953_393, 7_627_161, "44f28f921bfeafbd14c37884c1300c5c0566c3455b6a2009a0db9e0b427116d9"),
        ListSpec(Category.DRUGS, "lists/drugs.sgbl", 26_029, 208_248, "f8f9d4f0d61fba99bcbc4f9d05613db19ff50b646c6692cb5b40df68ed8db367"),
    )
}
