package dev.vivac.launcher.theme

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MotifsTest {
    @Test
    fun `the beam leaves its origin down and to the left, as a narrow cone`() {
        val origin = Offset(1000f, 150f)
        val (a, b) = beamEdges(origin, width = 1080f, height = 2400f)
        assertTrue(a.x < origin.x && b.x < origin.x)
        assertTrue(a.y > origin.y && b.y > origin.y)
        val angle = { p: Offset -> Math.toDegrees(kotlin.math.atan2((p.y - origin.y).toDouble(), (p.x - origin.x).toDouble())) }
        val spread = kotlin.math.abs(angle(a) - angle(b))
        assertTrue("spread $spread", spread in 15.0..30.0)
    }

    private fun radii(ring: Int) = Rings.points(ring, Offset(500f, 300f), inner = 80f).map { (it - Offset(500f, 300f)).getDistance() }

    @Test
    fun `the first ring is a perfect circle around the centre`() {
        radii(0).forEach { assertEquals(80f, it, 0.5f) }
    }

    @Test
    fun `each ring out is bigger and more uneven than the one inside it, and the last reaches far`() {
        val unevenness = (1 until Rings.COUNT).map { r -> radii(r).let { (it.max() - it.min()) / it.average().toFloat() } }
        assertTrue("unevenness $unevenness", unevenness.zipWithNext().all { (a, b) -> b > a })
        val means = (0 until Rings.COUNT).map { radii(it).average() }
        assertTrue(means.zipWithNext().all { (a, b) -> b > a })
        // The outermost ring is about twenty times the first: well past the screen from the corner.
        assertTrue(means.last() > 18 * 80)
    }

    @Test
    fun `now and then the beam reaches forward and flares, briefly and faintly`() {
        val flares = (0..200).map { Motion.flare(it / 200f) }
        assertEquals(0f, flares.first(), 1e-3f)
        assertEquals(1f, flares.max(), 0.02f)
        // Most of the time it rests.
        assertTrue(flares.count { it < 0.01f } > 150)
        assertTrue(Motion.SWAY_DEGREES >= 7f)
    }
}
