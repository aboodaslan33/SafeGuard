package com.safeguard.app.apps

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Shown when a protected app is opened. A regular activity (not an
 * overlay), built without Flutter so it appears instantly. It shows only
 * the app's name — nothing from inside the app.
 */
class AppBlockedActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val label = intent.getStringExtra(EXTRA_LABEL)?.take(80) ?: "هذا التطبيق"

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            layoutDirection = View.LAYOUT_DIRECTION_RTL
            setBackgroundColor(BACKGROUND)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        root.addView(text("🛡", 44f, ACCENT))
        root.addView(text("هذا التطبيق محمي", 22f, TEXT_PRIMARY, top = 16))
        root.addView(
            text("أضفت «$label» إلى التطبيقات المحمية في SafeGuard، لذلك لا يمكن فتحه الآن.", 15f, TEXT_SECONDARY, top = 8),
        )
        root.addView(
            Button(this).apply {
                text = "العودة إلى الشاشة الرئيسية"
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
    }

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

    companion object {
        const val EXTRA_LABEL = "label"
        private val BACKGROUND = Color.parseColor("#0D1012")
        private val ACCENT = Color.parseColor("#5BB89F")
        private val ON_ACCENT = Color.parseColor("#05201A")
        private val TEXT_PRIMARY = Color.parseColor("#E9EDEF")
        private val TEXT_SECONDARY = Color.parseColor("#A0AAB0")
    }
}
