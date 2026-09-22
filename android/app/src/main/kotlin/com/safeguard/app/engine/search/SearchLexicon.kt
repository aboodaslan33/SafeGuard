package com.safeguard.app.engine.search

import com.safeguard.app.engine.rules.Category

/**
 * One rule of the query classifier.
 *
 * [id] is what gets logged — never the term — so a log entry can be traced
 * to a rule without revealing what the user typed.
 */
data class LexiconEntry(
    val id: String,
    /** Phrase as written; normalised with [SearchNormalizer.normalizeTerm]. */
    val phrase: String,
    val category: Category,
    /** Contribution to the category score, 0..1. */
    val weight: Double,
)

/**
 * Terms that signal an informational, protective or medical intent. When
 * present, category scores are dampened so "sex education", "drug
 * addiction help" or "suicide prevention" aren't blocked.
 */
data class SafeContext(val phrase: String, val factor: Double = 0.4)

/**
 * The built-in rule set: deliberately small, generic and non-graphic.
 * It is a rule layer, not a content list; Phase 4 plugs an on-device
 * classifier in behind [SearchClassifier].
 */
object BuiltInSearchLexicon {
    const val VERSION = 1

    val entries: List<LexiconEntry> = listOf(
        // SEXUAL
        LexiconEntry("sx01", "porn", Category.SEXUAL, 1.0),
        LexiconEntry("sx02", "porno", Category.SEXUAL, 1.0),
        LexiconEntry("sx03", "xxx", Category.SEXUAL, 0.8),
        LexiconEntry("sx04", "nude", Category.SEXUAL, 0.7),
        LexiconEntry("sx05", "nudes", Category.SEXUAL, 0.8),
        LexiconEntry("sx06", "hentai", Category.SEXUAL, 1.0),
        LexiconEntry("sx07", "sex video", Category.SEXUAL, 1.0),
        LexiconEntry("sx08", "sex", Category.SEXUAL, 0.45),
        LexiconEntry("sx09", "erotic", Category.SEXUAL, 0.7),
        LexiconEntry("sx10", "اباحي", Category.SEXUAL, 1.0),
        LexiconEntry("sx11", "اباحيه", Category.SEXUAL, 1.0),
        LexiconEntry("sx12", "سكس", Category.SEXUAL, 1.0),
        LexiconEntry("sx13", "افلام اباحيه", Category.SEXUAL, 1.0),
        LexiconEntry("sx14", "عاريات", Category.SEXUAL, 0.9),
        LexiconEntry("sx15", "جنس", Category.SEXUAL, 0.45),

        // VIOLENCE
        LexiconEntry("vi01", "beheading", Category.VIOLENCE, 1.0),
        LexiconEntry("vi02", "execution video", Category.VIOLENCE, 1.0),
        LexiconEntry("vi03", "fight video", Category.VIOLENCE, 0.5),
        LexiconEntry("vi04", "torture video", Category.VIOLENCE, 1.0),
        LexiconEntry("vi05", "ذبح", Category.VIOLENCE, 0.8),
        LexiconEntry("vi06", "قطع راس", Category.VIOLENCE, 1.0),
        LexiconEntry("vi07", "فيديو تعذيب", Category.VIOLENCE, 1.0),
        LexiconEntry("vi08", "مقطع اعدام", Category.VIOLENCE, 1.0),

        // GORE
        LexiconEntry("go01", "gore", Category.GORE, 1.0),
        LexiconEntry("go02", "dismemberment", Category.GORE, 1.0),
        LexiconEntry("go03", "accident corpse", Category.GORE, 1.0),
        LexiconEntry("go04", "مشاهد دمويه", Category.GORE, 1.0),
        LexiconEntry("go05", "جثث", Category.GORE, 0.7),
        LexiconEntry("go06", "اشلاء", Category.GORE, 1.0),

        // GAMBLING
        LexiconEntry("ga01", "casino", Category.GAMBLING, 0.9),
        LexiconEntry("ga02", "online casino", Category.GAMBLING, 1.0),
        LexiconEntry("ga03", "betting", Category.GAMBLING, 0.8),
        LexiconEntry("ga04", "sports betting", Category.GAMBLING, 1.0),
        LexiconEntry("ga05", "poker online", Category.GAMBLING, 1.0),
        LexiconEntry("ga06", "slots", Category.GAMBLING, 0.6),
        LexiconEntry("ga07", "قمار", Category.GAMBLING, 1.0),
        LexiconEntry("ga08", "مراهنات", Category.GAMBLING, 1.0),
        LexiconEntry("ga09", "كازينو", Category.GAMBLING, 1.0),
        LexiconEntry("ga10", "رهان", Category.GAMBLING, 0.7),

        // DRUGS
        LexiconEntry("dr01", "buy cocaine", Category.DRUGS, 1.0),
        LexiconEntry("dr02", "cocaine", Category.DRUGS, 0.7),
        LexiconEntry("dr03", "buy weed", Category.DRUGS, 1.0),
        LexiconEntry("dr04", "meth", Category.DRUGS, 0.7),
        LexiconEntry("dr05", "heroin", Category.DRUGS, 0.7),
        LexiconEntry("dr06", "كوكايين", Category.DRUGS, 0.8),
        LexiconEntry("dr07", "حشيش", Category.DRUGS, 0.8),
        LexiconEntry("dr08", "شراء مخدرات", Category.DRUGS, 1.0),
        LexiconEntry("dr09", "مخدرات", Category.DRUGS, 0.5),
        LexiconEntry("dr10", "كبتاجون", Category.DRUGS, 0.9),

        // DANGEROUS
        LexiconEntry("dg01", "how to make a bomb", Category.DANGEROUS, 1.0),
        LexiconEntry("dg02", "make a bomb", Category.DANGEROUS, 1.0),
        LexiconEntry("dg03", "suicide methods", Category.DANGEROUS, 1.0),
        LexiconEntry("dg04", "how to kill myself", Category.DANGEROUS, 1.0),
        LexiconEntry("dg05", "self harm", Category.DANGEROUS, 0.7),
        LexiconEntry("dg06", "طريقه صنع قنبله", Category.DANGEROUS, 1.0),
        LexiconEntry("dg07", "صنع قنبله", Category.DANGEROUS, 1.0),
        LexiconEntry("dg08", "طرق الانتحار", Category.DANGEROUS, 1.0),
        LexiconEntry("dg09", "ايذاء النفس", Category.DANGEROUS, 0.7),
    )

    val safeContexts: List<SafeContext> = listOf(
        SafeContext("education"), SafeContext("health"), SafeContext("prevention"),
        SafeContext("help"), SafeContext("hotline"), SafeContext("addiction"),
        SafeContext("treatment"), SafeContext("recovery"), SafeContext("news"),
        SafeContext("cancer"), SafeContext("history"), SafeContext("awareness"),
        SafeContext("تعليم"), SafeContext("توعيه"), SafeContext("علاج"),
        SafeContext("صحه"), SafeContext("وقايه"), SafeContext("مساعده"),
        SafeContext("ادمان"), SafeContext("اخبار"), SafeContext("تاريخ"),
    )
}
