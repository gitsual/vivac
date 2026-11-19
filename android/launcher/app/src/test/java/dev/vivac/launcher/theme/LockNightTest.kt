package dev.vivac.launcher.theme

import androidx.compose.ui.graphics.toArgb
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LockNightTest {
    private val night = LockNight.paint(width = 1080, height = 2400, density = 2.625f)

    @Test
    fun `the lock screen's night fills the whole screen on vivac's deepest ground`() {
        assertEquals(1080, night.width)
        assertEquals(2400, night.height)
        // Bottom left, far from the lamp and outside the beam.
        assertEquals(Ink.deep.toArgb(), night.getPixel(10, 2390))
    }

    @Test
    fun `the lamp's circle and the beam are drawn from the top right corner, where the camp keeps them`() {
        val lamp = LockNight.lamp(1080, 2.625f)
        val inner = (LockNight.INNER_DP * 2.625f).toInt()
        // On the circle itself.
        assertNotEquals(Ink.deep.toArgb(), night.getPixel(lamp.x.toInt() - inner, lamp.y.toInt()))
        // Just inside the beam, below and left of the lamp, the glow warms the ground.
        val below = night.getPixel(lamp.x.toInt() - 40, lamp.y.toInt() + 160)
        assertNotEquals(Ink.deep.toArgb(), below)
    }
}
