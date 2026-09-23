package com.safeguard.app.engine.shield

/**
 * Read-only view of an accessibility node tree, so the extraction rules
 * below are testable without Android. The Android adapter wraps
 * `AccessibilityNodeInfo` and recycles nodes in [release].
 */
interface NodeView<N> {
    fun childCount(n: N): Int
    fun child(n: N, i: Int): N?
    fun text(n: N): CharSequence?
    fun description(n: N): CharSequence?
    fun isEditable(n: N): Boolean
    fun isPassword(n: N): Boolean
    fun isVisible(n: N): Boolean

    /** Called once for every node obtained through [child] (not the root). */
    fun release(n: N) {}
}

/**
 * Collects the text a supported app shows on screen, for in-memory
 * classification only. It is never stored, logged or sent anywhere.
 *
 * Privacy rules, applied before anything reaches the classifier:
 * - editable fields (anything being typed: messages, search boxes, the
 *   address bar) and password fields are skipped, with their subtrees;
 * - invisible nodes are skipped;
 * - fragments that look like one-time codes, card/account numbers, e-mail
 *   addresses, links or other number-heavy data are dropped (they carry no
 *   signal and may be sensitive);
 * - the walk is bounded (nodes, depth, characters) so a huge screen can't
 *   cost unbounded time or memory.
 */
object VisibleTextExtractor {
    data class Limits(
        val maxNodes: Int = 400,
        val maxDepth: Int = 30,
        val maxChars: Int = 2_000,
        val maxFragmentChars: Int = 300,
    )

    fun <N> extract(root: N, view: NodeView<N>, limits: Limits = Limits()): String {
        val out = StringBuilder()
        val seen = HashSet<String>()
        var visited = 0

        fun add(raw: CharSequence?) {
            val s = raw?.toString()?.trim()?.take(limits.maxFragmentChars) ?: return
            if (s.length < 2 || !isClassifiable(s) || !seen.add(s)) return
            val room = limits.maxChars - out.length
            if (room <= 1) return
            if (out.isNotEmpty()) out.append('\n')
            out.append(s.take(room - 1))
        }

        fun walk(n: N, depth: Int) {
            if (visited >= limits.maxNodes || out.length >= limits.maxChars) return
            visited++
            if (view.isPassword(n) || view.isEditable(n)) return
            if (!view.isVisible(n)) return
            add(view.text(n))
            add(view.description(n))
            if (depth >= limits.maxDepth) return
            val count = view.childCount(n).coerceAtMost(limits.maxNodes)
            for (i in 0 until count) {
                if (visited >= limits.maxNodes || out.length >= limits.maxChars) break
                val c = view.child(n, i) ?: continue
                try {
                    walk(c, depth + 1)
                } finally {
                    view.release(c)
                }
            }
        }

        walk(root, 0)
        return out.toString()
    }

    private val EMAIL = Regex("[\\w.+-]+@[\\w-]+\\.[\\w.]+")
    private val LINK = Regex("(?i)\\b(?:https?://|www\\.)\\S+")
    private val LONG_NUMBER = Regex("\\d{6,}")

    /** False for fragments that look like codes, numbers, e-mails or links. */
    fun isClassifiable(s: String): Boolean {
        if (EMAIL.containsMatchIn(s) || LINK.containsMatchIn(s)) return false
        val digits = s.count { it.isDigit() }
        val letters = s.count { it.isLetter() }
        if (letters == 0) return false
        // OTPs, card/IBAN/account numbers, phone numbers, amounts.
        if (digits >= 4 && digits * 10 >= (digits + letters) * 3) return false
        if (LONG_NUMBER.containsMatchIn(s.replace(" ", "").replace("-", ""))) return false
        return true
    }
}
