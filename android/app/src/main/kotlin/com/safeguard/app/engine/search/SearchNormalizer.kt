package com.safeguard.app.engine.search

import java.text.Normalizer
import java.util.Locale

/** A query reduced to comparable tokens. Never persisted or logged. */
class NormalizedQuery(val text: String, val tokens: List<String>) {
    val isEmpty: Boolean get() = tokens.isEmpty()
}

/**
 * Normalises Arabic, English and mixed-language search text so spelling
 * variants compare equal:
 *
 * - Unicode NFKC, then diacritics removed (Arabic tashkeel, Latin accents)
 * - Arabic letter variants unified (أ إ آ ٱ → ا, ى → ي, ة → ه, ؤ → و, ئ → ي)
 * - tatweel removed, Arabic-Indic / Persian digits → ASCII
 * - lower case, punctuation and symbols → spaces, whitespace collapsed
 *
 * Length is capped so a pathological input can't cost more than a few
 * microseconds.
 */
object SearchNormalizer {
    const val MAX_INPUT = 512
    private const val MAX_TOKENS = 64

    fun normalize(raw: String): NormalizedQuery {
        val clipped = if (raw.length > MAX_INPUT) raw.substring(0, MAX_INPUT) else raw
        val composed = Normalizer.normalize(clipped, Normalizer.Form.NFKC)
        val stripped = Normalizer.normalize(composed, Normalizer.Form.NFD)
        val sb = StringBuilder(stripped.length)
        for (ch in stripped) {
            when {
                Character.getType(ch) == Character.NON_SPACING_MARK.toInt() -> Unit // diacritics
                ch == 'ـ' -> Unit // tatweel
                ch in '٠'..'٩' -> sb.append('0' + (ch - '٠'))
                ch in '۰'..'۹' -> sb.append('0' + (ch - '۰'))
                ch == 'أ' || ch == 'إ' || ch == 'آ' || ch == 'ٱ' -> sb.append('ا')
                ch == 'ى' -> sb.append('ي')
                ch == 'ة' -> sb.append('ه')
                ch == 'ؤ' -> sb.append('و')
                ch == 'ئ' -> sb.append('ي')
                Character.isLetterOrDigit(ch) -> sb.append(ch)
                else -> sb.append(' ') // punctuation, symbols, whitespace
            }
        }
        val text = sb.toString().lowercase(Locale.ROOT).trim().replace(Regex("\\s+"), " ")
        val tokens = if (text.isEmpty()) emptyList() else text.split(' ').take(MAX_TOKENS)
        return NormalizedQuery(tokens.joinToString(" "), tokens)
    }

    /** Normalises a lexicon term with the same rules (so both sides agree). */
    fun normalizeTerm(term: String): List<String> = normalize(term).tokens

    /**
     * Spelling variants a single token may match: as typed, with character
     * runs squeezed ("pooorn" → "porn"), and without Arabic prefixes
     * ("والقمار" → "قمار").
     */
    fun variants(token: String): Set<String> {
        val out = linkedSetOf(token, squeeze(token, 1), squeeze(token, 2))
        for (prefix in ARABIC_PREFIXES) {
            if (token.startsWith(prefix) && token.length - prefix.length >= 3) {
                val base = token.substring(prefix.length)
                out += base
                out += squeeze(base, 1)
            }
        }
        return out
    }

    /** Collapses runs of the same character longer than [max]. */
    fun squeeze(token: String, max: Int): String {
        val sb = StringBuilder(token.length)
        var run = 0
        var prev = '\u0000'
        for (c in token) {
            run = if (c == prev) run + 1 else 1
            prev = c
            if (run <= max) sb.append(c)
        }
        return sb.toString()
    }

    // Longest first so "وال" is tried before "و".
    private val ARABIC_PREFIXES = listOf("وال", "بال", "فال", "كال", "لل", "ال")
}
