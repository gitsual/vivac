package dev.vivac.launcher.campamento

import dev.vivac.launcher.core.TwoFinger
import org.junit.Assert.assertEquals
import org.junit.Test

class TwoFingersTest {
    @Test
    fun `fingers closing in are a pinch, two moving together are a swipe, anything less is nothing`() {
        assertEquals(TwoFinger.PINCH, TwoFingers.classify(startDistance = 600f, endDistance = 300f, dyDp = 0f))
        assertEquals(TwoFinger.TWO_DOWN, TwoFingers.classify(600f, 590f, dyDp = 120f))
        assertEquals(TwoFinger.TWO_UP, TwoFingers.classify(600f, 610f, dyDp = -120f))
        assertEquals(null, TwoFingers.classify(600f, 560f, dyDp = 20f))
        assertEquals(null, TwoFingers.classify(0f, 0f, dyDp = 0f))
    }
}
