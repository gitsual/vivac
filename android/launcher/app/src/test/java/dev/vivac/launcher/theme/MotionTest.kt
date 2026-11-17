package dev.vivac.launcher.theme

import android.app.Application
import android.provider.Settings
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MotionTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()

    @Test
    fun `the waves move by default`() {
        assertTrue(Motion.allowed(app))
    }

    @Test
    fun `they stay still when Android's animations are switched off`() {
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        assertFalse(Motion.allowed(app))
    }

    @Test
    fun `each ring swells a little after the one inside it, so the swell travels outwards`() {
        val inner = Motion.swell(phase = 0.25f, ring = 0, rings = 5)
        val outer = Motion.swell(phase = 0.25f, ring = 4, rings = 5)
        assertEquals(1f + Motion.AMPLITUDE, inner, 1e-4f)
        assertTrue(outer < inner)
        assertTrue((0..4).all { r -> Motion.swell(0.6f, r, 5) in (1f - Motion.AMPLITUDE)..(1f + Motion.AMPLITUDE) })
    }

    @Test
    fun `the headlamp sways a few degrees each way and starts centred`() {
        assertEquals(0f, Motion.sway(0f), 1e-4f)
        assertEquals(Motion.SWAY_DEGREES, Motion.sway(0.25f), 1e-4f)
        assertEquals(-Motion.SWAY_DEGREES, Motion.sway(0.75f), 1e-4f)
    }

    @Test
    fun `its glow breathes between a dim and a bright edge, never off`() {
        val glows = (0..20).map { Motion.glow(it / 20f) }
        assertTrue(glows.all { it in Motion.GLOW_MIN..Motion.GLOW_MAX })
        assertTrue(glows.minOrNull()!! < glows.maxOrNull()!!)
        assertTrue(Motion.GLOW_MIN > 0f)
    }
}
