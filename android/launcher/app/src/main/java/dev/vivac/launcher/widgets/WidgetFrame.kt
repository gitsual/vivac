package dev.vivac.launcher.widgets

import android.appwidget.AppWidgetHostView
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.ViewConfiguration
import kotlin.math.abs

/**
 * A widget's live view that also listens for a held finger. Taps and scrolls stay the widget's; holding still
 * for the long-press time hands the gesture to vivac, which opens the widget's card.
 */
class WidgetFrame(context: Context) : AppWidgetHostView(context) {
    var onLongPress: (() -> Unit)? = null

    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    // Not View.postDelayed: that waits for the view to be attached, and the timer must start on the touch itself.
    private val clock = Handler(Looper.getMainLooper())
    private var downX = 0f
    private var downY = 0f
    private var held = false
    private val press = Runnable {
        held = true
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        // Children stop treating this as their press (no click on release).
        cancelLongPress()
        onLongPress?.invoke()
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                held = false
                downX = event.x
                downY = event.y
                clock.postDelayed(press, ViewConfiguration.getLongPressTimeout().toLong())
            }
            MotionEvent.ACTION_MOVE -> if (abs(event.x - downX) > slop || abs(event.y - downY) > slop) clock.removeCallbacks(press)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> clock.removeCallbacks(press)
        }
        return held
    }

    /** Once held, the rest of the gesture is vivac's: swallow it so the widget never sees a click. */
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) clock.removeCallbacks(press)
        return held || super.onTouchEvent(event)
    }
}
