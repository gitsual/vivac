package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Test

class SwipeTest {
    @Test
    fun `a long enough drag down opens notifications, up opens the Petate`() {
        assertEquals(Swipe.DOWN, Swipe.classify(dyDp = 80f, velocityDp = 0f))
        assertEquals(Swipe.UP, Swipe.classify(dyDp = -80f, velocityDp = 0f))
    }

    @Test
    fun `a short but fast flick also counts`() {
        assertEquals(Swipe.DOWN, Swipe.classify(dyDp = 20f, velocityDp = 900f))
        assertEquals(Swipe.UP, Swipe.classify(dyDp = -20f, velocityDp = -900f))
    }

    @Test
    fun `a small slow drag is just a wobble`() {
        assertEquals(Swipe.NONE, Swipe.classify(dyDp = 30f, velocityDp = 200f))
        assertEquals(Swipe.NONE, Swipe.classify(dyDp = 0f, velocityDp = 0f))
    }

    @Test
    fun `a finger tremor during a long press is not a flick, however fast it measures`() {
        // Seen on the Pixel: 1px of travel during a long press measured as a fast flick.
        assertEquals(Swipe.NONE, Swipe.classify(dyDp = 0.4f, velocityDp = 2000f))
        assertEquals(Swipe.NONE, Swipe.classify(dyDp = -8f, velocityDp = -2000f))
    }

    @Test
    fun `a flick against the drag direction is ignored`() {
        assertEquals(Swipe.NONE, Swipe.classify(dyDp = 20f, velocityDp = -900f))
    }
}
