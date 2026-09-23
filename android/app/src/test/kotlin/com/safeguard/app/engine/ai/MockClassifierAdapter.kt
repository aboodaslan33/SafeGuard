package com.safeguard.app.engine.ai

import com.safeguard.app.engine.rules.Category

/**
 * Test-only adapter returning fixed scores. It lives in test sources so it
 * can never ship in the app.
 */
class MockClassifierAdapter(
    private val kinds: Set<ContentKind> = setOf(ContentKind.TEXT, ContentKind.IMAGE),
    override val id: String = "mock",
    override val isRemote: Boolean = false,
    var available: Boolean = true,
    var status: ClassificationStatus = ClassificationStatus.OK,
    var scores: Map<Category, Double> = emptyMap(),
) : ClassifierAdapter {
    var calls = 0
        private set

    override fun supports(kind: ContentKind) = kind in kinds
    override val isAvailable get() = available

    override fun classify(input: ContentInput): ClassificationResult {
        calls++
        val risk = scores.filterKeys { it.isFilterable }
        return ClassificationResult(status, risk + (Category.SAFE to ClassificationResult.safeScore(risk)), id)
    }

    companion object {
        fun result(vararg s: Pair<Category, Double>, status: ClassificationStatus = ClassificationStatus.OK): ClassificationResult {
            val risk = s.toMap()
            return ClassificationResult(status, risk + (Category.SAFE to ClassificationResult.safeScore(risk)), "mock")
        }
    }
}
