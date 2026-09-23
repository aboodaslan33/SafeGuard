package com.safeguard.app.shield

import android.accessibilityservice.AccessibilityService
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.safeguard.app.R

/**
 * The screen SafeGuard puts over blocked content, so the user stays in the
 * app but doesn't see it.
 *
 * - Drawn by the shield's own accessibility service as an accessibility
 *   overlay (no "draw over other apps" permission). It shows only SafeGuard's
 *   message; it reads nothing and captures nothing.
 * - [flash]: a short cover that doesn't take touches, while the content is
 *   swiped away underneath.
 * - [hold]: stays until the user taps "Next" or "Back" (or leaves the app).
 * - While a cover is up, screen frames show the cover, not the app, so
 *   image checks pause ([showing]).
 */
class ShieldCover(
    private val service: AccessibilityService,
    private val arabic: () -> Boolean,
    private val onNext: () -> Unit,
    private val onBack: () -> Unit,
    private val onHidden: () -> Unit,
) {
    private val wm = service.getSystemService(WindowManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    /** Only changed on the main thread; read from the capture thread through [showing]. */
    @Volatile private var view: View? = null
    private val autoHide = Runnable { hide() }

    val showing: Boolean get() = view != null

    /** Covers the screen for [durationMs] without taking touches. */
    fun flash(message: Message, durationMs: Long) {
        show(message, touchable = false)
        main.removeCallbacks(autoHide)
        main.postDelayed(autoHide, durationMs)
    }

    /** Covers the screen until the user picks "Next" or "Back". */
    fun hold(message: Message) {
        main.removeCallbacks(autoHide)
        show(message, touchable = true)
    }

    fun hide() {
        main.removeCallbacks(autoHide)
        val v = view ?: return
        view = null
        try {
            wm?.removeViewImmediate(v)
        } catch (e: RuntimeException) {
            // Already gone with the service's window token.
        }
        onHidden()
    }

    private fun show(message: Message, touchable: Boolean) {
        val manager = wm ?: return
        val old = view
        val v = build(message, touchable)
        val flags = WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            (if (touchable) 0 else WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            flags,
            PixelFormat.OPAQUE,
        )
        try {
            manager.addView(v, params)
            view = v
        } catch (e: RuntimeException) {
            return // no window token (service disconnecting)
        }
        if (old != null) {
            try {
                manager.removeViewImmediate(old)
            } catch (e: RuntimeException) {
                // ignore
            }
        }
    }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), service.resources.displayMetrics).toInt()

    private fun build(message: Message, touchable: Boolean): View {
        val ar = arabic()
        val box = LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.rgb(16, 24, 32))
            setPadding(dp(32), dp(32), dp(32), dp(32))
            layoutDirection = if (ar) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR
            // A cover that takes touches must not let them reach the app underneath.
            isClickable = touchable
        }
        box.addView(
            ImageView(service).apply { setImageResource(R.drawable.ic_shield_mark) },
            LinearLayout.LayoutParams(dp(72), dp(72)),
        )
        fun label(text: String, size: Float, alpha: Int) = TextView(service).apply {
            this.text = text
            textSize = size
            gravity = Gravity.CENTER
            setTextColor(Color.argb(alpha, 255, 255, 255))
            setPadding(0, dp(12), 0, 0)
        }
        box.addView(label(message.title(ar), 20f, 255))
        box.addView(label(message.detail(ar), 15f, 200))
        if (touchable) {
            val row = LinearLayout(service).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(0, dp(28), 0, 0)
            }
            fun button(text: String, filled: Boolean, action: () -> Unit) = Button(service).apply {
                this.text = text
                isAllCaps = false
                setTextColor(if (filled) Color.rgb(16, 24, 32) else Color.WHITE)
                background = GradientDrawable().apply {
                    cornerRadius = dp(24).toFloat()
                    if (filled) setColor(Color.rgb(94, 234, 212)) else setStroke(dp(1), Color.WHITE)
                }
                setPadding(dp(24), 0, dp(24), 0)
                setOnClickListener {
                    hide()
                    action()
                }
            }
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(48)).apply { marginStart = dp(8); marginEnd = dp(8) }
            row.addView(button(if (ar) "التالي" else "Next", true, onNext), lp)
            row.addView(button(if (ar) "رجوع" else "Back", false, onBack), lp)
            box.addView(row)
        }
        return box
    }

    /** What the cover says. Content-free: only the category. */
    enum class Message(private val en: Pair<String, String>, private val ar: Pair<String, String>) {
        CONTENT(
            "Content hidden" to "SafeGuard hid content that doesn't match your protection settings.",
            "تم حجب المحتوى" to "أخفى SafeGuard محتوى لا يتوافق مع إعدادات الحماية.",
        ),
        CONTENT_REPEATED(
            "Content hidden" to "This screen keeps showing blocked content. Go to the next item or back.",
            "تم حجب المحتوى" to "هذه الشاشة ما زالت تعرض محتوى محجوبًا. انتقل للتالي أو ارجع.",
        ),
        SEARCH(
            "Search blocked" to "This search isn't allowed by your protection settings.",
            "تم حظر البحث" to "هذا البحث غير مسموح حسب إعدادات الحماية.",
        ),
        ;

        fun title(arabic: Boolean) = (if (arabic) ar else en).first
        fun detail(arabic: Boolean) = (if (arabic) ar else en).second
    }
}
