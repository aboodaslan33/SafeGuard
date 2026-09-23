package com.safeguard.app.engine.updates

import com.safeguard.app.engine.ai.text.TextModel
import com.safeguard.app.engine.rules.HashedDomainList
import java.nio.ByteBuffer

/** Validators for the payload formats SafeGuard can already read. */
object UpdateValidators {
    /** A domain list must parse and belong to the category it claims (its id). */
    val domainList = PayloadValidator { m, payload ->
        val list = HashedDomainList.parse(ByteBuffer.wrap(payload))
        if (list.category.id != m.id) throw UpdateRejected(Rejection.INVALID_PAYLOAD, "category mismatch")
        if (list.size == 0) throw UpdateRejected(Rejection.INVALID_PAYLOAD, "empty list")
    }

    /**
     * An AI model must parse, and must behave within tolerance on a fixed
     * probe set before it may replace the active one.
     */
    fun aiModel(probe: (TextModel) -> Boolean) = PayloadValidator { _, payload ->
        val model = TextModel.parse(payload)
        if (!probe(model)) throw UpdateRejected(Rejection.INVALID_PAYLOAD, "probe failed")
    }
}
