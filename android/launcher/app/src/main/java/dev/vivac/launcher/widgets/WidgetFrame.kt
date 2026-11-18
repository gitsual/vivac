package dev.vivac.launcher.widgets

import android.appwidget.AppWidgetHostView
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.ViewConfiguration
import kotlin.math.abs

/** What vivac does with a finger held on a widget: lift it, follow the finger, and land it or open its card. */
interface Grip {
    /** The long press: the widget is lifted with the finger at ([x], [y]) inside it; [look] is a picture of it to carry. */
    fun lift(x: Float, y: Float, look: Bitmap? = null)
    fun move(dx: Float, dy: Float)
    /** Let go: [moved] tells a carry from a plain hold, which opens the widget's card. */
    fun land(moved: Boolean)
    /** The system took the gesture back. */
    fun cancel()
}

/**
 * A widget's live view that also listens for a held finger. Taps and scrolls stay the widget's; holding still
 * for the long-press time hands the rest of the gesture to vivac's [grip].
 */
class WidgetFrame(context: Context) : AppWidgetHostView(context) {
    var grip: Grip? = null

    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    // Not View.postDelayed: that waits for the view to be attached, and the timer must start on the touch itself.
    private val clock = Handler(Looper.getMainLooper())
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var travelled = 0f
    private var held = false
    private val press = Runnable {
        held = true
        travelled = 0f
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        // Children stop treating this as their press (no click on release), and no parent scrolls it away.
        cancelLongPress()
        parent?.requestDisallowInterceptTouchEvent(true)
        grip?.lift(lastX, lastY, picture())
    }

    /** The widget as it looks now, or null before it has a size. */
    private fun picture(): Bitmap? =
        if (width <= 0 || height <= 0) null
        else Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { draw(Canvas(it)) }

    /**
     * Every finger on the widget passes here first, so the hold's timer always learns of a release or a scroll.
     * The gesture is kept even over a part of the widget that takes no touches: otherwise the parent stops passing
     * it on, a release is never seen, and a widget lifted by the timer would stay up under no finger.
     */
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                held = false
                downX = event.x; downY = event.y
                lastX = event.x; lastY = event.y
                clock.postDelayed(press, ViewConfiguration.getLongPressTimeout().toLong())
            }
            MotionEvent.ACTION_MOVE -> if (!held && (abs(event.x - downX) > slop || abs(event.y - downY) > slop)) {
                clock.removeCallbacks(press)
                // Up or down is the widget's own (its list, its scroll), not the page's; sideways still turns the page.
                if (abs(event.y - downY) > abs(event.x - downX)) parent?.requestDisallowInterceptTouchEvent(true)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> clock.removeCallbacks(press)
        }
        return super.dispatchTouchEvent(event) || event.actionMasked == MotionEvent.ACTION_DOWN
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = held

    /** Once held, the rest of the gesture is vivac's: it carries the widget, and the widget never sees a click. */
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!held) return super.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                val dx = event.x - lastX
                val dy = event.y - lastY
                lastX = event.x; lastY = event.y
                travelled += abs(dx) + abs(dy)
                grip?.move(dx, dy)
            }
            MotionEvent.ACTION_UP -> { held = false; grip?.land(travelled > slop) }
            MotionEvent.ACTION_CANCEL -> { held = false; grip?.cancel() }
        }
        return true
    }
}
