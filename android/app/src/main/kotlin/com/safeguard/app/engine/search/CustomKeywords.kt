package com.safeguard.app.engine.search

import com.safeguard.app.engine.rules.Category

/** A user-defined blocked keyword or phrase (stored normalised). */
data class CustomKeyword(val id: Long, val phrase: String, val category: Category, val addedAt: Long)

enum class KeywordError(val code: String) {
    INVALID_KEYWORD("INVALID_KEYWORD"),
    KEYWORD_TOO_SHORT("KEYWORD_TOO_SHORT"),
    INVALID_CATEGORY("INVALID_CATEGORY"),
    DUPLICATE_KEYWORD("DUPLICATE_KEYWORD"),
    LIMIT_REACHED("LIMIT_REACHED"),
}

class KeywordException(val error: KeywordError) : IllegalArgumentException(error.code)

interface CustomKeywordStore {
    fun list(): List<CustomKeyword>
    fun add(phrase: String, category: Category, addedAt: Long): CustomKeyword
    fun remove(id: Long): Boolean
    fun count(): Int
    fun clear()
}

class InMemoryCustomKeywordStore : CustomKeywordStore {
    private val items = LinkedHashMap<Long, CustomKeyword>()
    private var nextId = 1L

    @Synchronized override fun list() = items.values.toList()
    @Synchronized override fun add(phrase: String, category: Category, addedAt: Long) =
        CustomKeyword(nextId++, phrase, category, addedAt).also { items[it.id] = it }
    @Synchronized override fun remove(id: Long) = items.remove(id) != null
    @Synchronized override fun count() = items.size
    @Synchronized override fun clear() = items.clear()
}

/**
 * Validation and matching for user keywords.
 *
 * False-positive safeguards: keywords match whole words and whole
 * phrases only (never inside another word: "ass" does not match "class"
 * or "passport"); single-word keywords need at least 3 letters; digits-
 * only keywords are refused; at most [MAX_WORDS] words. Keywords are one
 * signal in the search pipeline — the built-in lexicon and AI still run
 * for everything the keywords don't cover.
 */
class CustomKeywords(
    private val store: CustomKeywordStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val max: Int = MAX_KEYWORDS,
) {
    @Volatile private var matcher: RuleBasedSearchClassifier? = null

    fun list() = store.list()

    fun add(raw: String, category: Category): CustomKeyword {
        val phrase = normalize(raw)
        if (!category.isUserAssignable) throw KeywordException(KeywordError.INVALID_CATEGORY)
        if (store.list().any { it.phrase == phrase }) throw KeywordException(KeywordError.DUPLICATE_KEYWORD)
        if (store.count() >= max) throw KeywordException(KeywordError.LIMIT_REACHED)
        return store.add(phrase, category, clock()).also { matcher = null }
    }

    fun remove(id: Long): Boolean = store.remove(id).also { if (it) matcher = null }

    fun clear() {
        store.clear()
        matcher = null
    }

    /** The first matching keyword for [query], or null. */
    fun match(query: NormalizedQuery): CustomKeyword? {
        if (query.isEmpty) return null
        val keywords = store.list()
        if (keywords.isEmpty()) return null
        val m = matcher ?: RuleBasedSearchClassifier(
            entries = keywords.map { LexiconEntry("u${it.id}", it.phrase, it.category, 1.0) },
            safeContexts = emptyList(), // explicit user intent is not damped
        ).also { matcher = it }
        val id = m.classify(query).matchedRuleIds.firstOrNull() ?: return null
        return keywords.firstOrNull { "u${it.id}" == id }
    }

    companion object {
        const val MAX_KEYWORDS = 500
        const val MAX_WORDS = 5
        const val MAX_LENGTH = 64

        fun normalize(raw: String): String {
            if (raw.length > 256) throw KeywordException(KeywordError.INVALID_KEYWORD)
            val tokens = SearchNormalizer.normalizeTerm(raw)
            if (tokens.isEmpty() || tokens.size > MAX_WORDS) throw KeywordException(KeywordError.INVALID_KEYWORD)
            val phrase = tokens.joinToString(" ")
            if (phrase.length > MAX_LENGTH) throw KeywordException(KeywordError.INVALID_KEYWORD)
            if (tokens.all { t -> t.all { it.isDigit() } }) throw KeywordException(KeywordError.INVALID_KEYWORD)
            if (tokens.size == 1 && tokens[0].length < 3) throw KeywordException(KeywordError.KEYWORD_TOO_SHORT)
            return phrase
        }
    }
}
