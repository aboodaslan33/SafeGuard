package com.safeguard.app.apps

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.window.OnBackInvokedDispatcher
import com.safeguard.app.protection.ProtectionManager

/**
 * Shown when a protected app is opened. A regular activity (not an
 * overlay), built without Flutter so it appears instantly. It shows only
 * the app's name — nothing from inside the app.
 */
class AppBlockedActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Follows the language chosen in SafeGuard (synced from Flutter).
        val en = ProtectionManager.get(this).config.uiLanguage == "en"
        fun tr(ar: String, english: String) = if (en) english else ar
        val label = intent.getStringExtra(EXTRA_LABEL)?.take(80) ?: tr("هذا التطبيق", "this app")
        // KIND_CONTENT: the AI Content Shield blocked something inside an app.
        // Only the category is shown — never the content itself.
        val content = intent.getStringExtra(EXTRA_KIND) == KIND_CONTENT
        val category = categoryName(intent.getStringExtra(EXTRA_CATEGORY), en)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            layoutDirection = if (en) View.LAYOUT_DIRECTION_LTR else View.LAYOUT_DIRECTION_RTL
            setBackgroundColor(BACKGROUND)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        root.addView(text("🛡", 44f, ACCENT))
        if (content) {
            root.addView(text(tr("تم حظر هذا المحتوى", "This content was blocked"), 22f, TEXT_PRIMARY, top = 16))
            root.addView(
                text(
                    tr(
                        "تم اكتشاف محتوى لا يتوافق مع إعدادات الحماية.",
                        "Content that doesn't match your protection settings was detected.",
                    ),
                    15f,
                    TEXT_SECONDARY,
                    top = 8,
                ),
            )
            if (category != null) root.addView(text(tr("الفئة: $category", "Category: $category"), 14f, TEXT_SECONDARY, top = 8))
        } else {
            root.addView(text(tr("هذا التطبيق محمي", "This app is protected"), 22f, TEXT_PRIMARY, top = 16))
            root.addView(
                text(
                    tr(
                        "أضفت «$label» إلى التطبيقات المحمية في SafeGuard، لذلك لا يمكن فتحه الآن.",
                        "You added “$label” to protected apps in SafeGuard, so it can't be opened now.",
                    ),
                    15f,
                    TEXT_SECONDARY,
                    top = 8,
                ),
            )
        }
        root.addView(
            Button(this).apply {
                text = tr("العودة إلى الشاشة الرئيسية", "Back to home screen")
                setTextColor(ON_ACCENT)
                isAllCaps = false
                background = GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat()
                    setColor(ACCENT)
                }
                setOnClickListener { goHome() }
            },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(52)).apply { topMargin = dp(32) },
        )
        setContentView(root)
        // Back always leads home, never back into the protected app. On
        // API 33+ with predictive back (default from Android 16) a back
        // gesture doesn't call onBackPressed, so register a callback.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) { goHome() }
        }
    }

    // Older Android versions (and API 33 without predictive back).
    @SuppressLint("GestureBackNavigation")
    @Deprecated("Back always leads home, never back into the protected app.")
    override fun onBackPressed() = goHome()

    private fun goHome() {
        startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }

    private fun text(value: String, sizeSp: Float, color: Int, top: Int = 0) = TextView(this).apply {
        text = value
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        gravity = Gravity.CENTER
        textAlignment = View.TEXT_ALIGNMENT_CENTER
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(top) }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    /** Localised name of a category id, or null for ids SafeGuard doesn't show. */
    private fun categoryName(id: String?, en: Boolean): String? = when (id) {
        "sexual" -> if (en) "Sexual content" else "محتوى جنسي"
        "violence" -> if (en) "Violence" else "عنف"
        "gore" -> if (en) "Gore" else "محتوى دموي"
        "gambling" -> if (en) "Gambling" else "قمار"
        "drugs" -> if (en) "Drugs" else "مخدرات"
        "dangerous" -> if (en) "Dangerous content" else "محتوى خطير"
        else -> null
    }

    companion object {
        const val EXTRA_LABEL = "label"
        const val EXTRA_KIND = "kind"
        const val EXTRA_CATEGORY = "category"
        const val KIND_CONTENT = "content"
        private val BACKGROUND = Color.parseColor("#0D1012")
        private val ACCENT = Color.parseColor("#5BB89F")
        private val ON_ACCENT = Color.parseColor("#05201A")
        private val TEXT_PRIMARY = Color.parseColor("#E9EDEF")
        private val TEXT_SECONDARY = Color.parseColor("#A0AAB0")
    }
}
