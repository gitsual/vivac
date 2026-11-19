package dev.vivac.launcher.campamento

import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import dev.vivac.launcher.core.TwoFinger

/** Pure rules for two-finger gestures: what a pair of fingers did, from where they started to where they left. */
object TwoFingers {
    /** Closing to three quarters of the gap or less is a pinch. */
    private const val PINCH_RATIO = 0.75f
    /** Moving together this far, up or down, is a two-finger swipe. */
    private const val SWIPE_DP = 60f

    fun classify(startDistance: Float, endDistance: Float, dyDp: Float): TwoFinger? = when {
        startDistance > 0f && endDistance / startDistance <= PINCH_RATIO -> TwoFinger.PINCH
        dyDp >= SWIPE_DP -> TwoFinger.TWO_DOWN
        dyDp <= -SWIPE_DP -> TwoFinger.TWO_UP
        else -> null
    }
}

/** Shared by the camp's touch handlers: true from the moment a second finger lands until the next gesture starts. */
class TwoFingerState { var active = false }

/**
 * Watches every touch on the camp before anything else does (the initial pass) and, once two fingers are down,
 * reports what they did when the last one lifts. It consumes nothing; the one-finger swipe handlers ask [state]
 * and stay quiet for a two-finger gesture.
 */
fun Modifier.twoFingers(state: TwoFingerState, onGesture: (TwoFinger) -> Unit): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        state.active = false
        var startDistance = 0f
        var startY = 0f
        var endDistance = 0f
        var endY = 0f
        do {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            val pressed = event.changes.filter { it.pressed }
            if (pressed.size >= 2) {
                val (a, b) = pressed[0].position to pressed[1].position
                val distance = (a - b).getDistance()
                val y = (a.y + b.y) / 2f
                if (!state.active) {
                    state.active = true
                    startDistance = distance
                    startY = y
                }
                endDistance = distance
                endY = y
            }
        } while (event.changes.any { it.pressed })
        if (state.active) TwoFingers.classify(startDistance, endDistance, (endY - startY) / density)?.let(onGesture)
    }
}

/** Apps on the camp with a flick action, what runs it, and the claim that keeps the camp from swiping as well. */
class Flicks(val apps: Set<String>, val run: (String) -> Unit, val claim: TwoFingerState?) {
    companion object { val NONE = Flicks(emptySet(), {}, null) }
}

val LocalFlicks = androidx.compose.runtime.staticCompositionLocalOf { Flicks.NONE }
