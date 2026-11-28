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

    private fun radii(ring: Int) = Rings.points(ring.toFloat(), Offset(500f, 300f), inner = 80f).map { (it - Offset(500f, 300f)).getDistance() }

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

    @Test
    fun `the travelling rings loop seamlessly, the end of one round the start of the next`() {
        val start = Rings.travelling(0f).map { it.first to it.second }
        val end = Rings.travelling(0.9999f).map { it.first to it.second }
        // Each ring at the end sits where the next one was at the start, as visible.
        start.drop(1).zip(end.dropLast(1)).forEach { (s, e) ->
            assertEquals(s.first, e.first, 0.01f)
            assertEquals(s.second, e.second, 0.01f)
        }
        // A new ring is born faint at the circle and the last fades out far away.
        assertEquals(0f, start.first().second, 0.01f)
        assertEquals(0f, end.last().second, 0.01f)
    }

    @Test
    fun `the beam swings from down the left to past the right edge, at the speed it had`() {
        // At its furthest right, the cone's right edge points right of straight down, so it leaves by the right side.
        assertTrue(BEAM_ANGLE - Motion.SWAY_DEGREES - BEAM_HALF < 80f)
        // At its furthest left it still points down and to the left.
        assertTrue(BEAM_ANGLE + Motion.SWAY_DEGREES + BEAM_HALF < 180f)
        // The swing is wider but no faster: the same degrees per second at its quickest as before (8° every 14 s).
        assertEquals(8f / 14_000f, Motion.SWAY_DEGREES / Motion.LAMP_PERIOD_MS, 1e-5f)
    }

    @Test
    fun `the rings travel slowly`() {
        assertTrue(Rings.STEP_MS >= 6_000)
    }

    @Test
    fun `the last full ring reaches past the screen's far side, wherever the lamp is`() {
        val inner = 26f * 2.625f
        // On its side the lamp is far from the left edge: the rings spread to cross it.
        val wide = Rings.spread(inner, reach = 868f * 2.625f)
        val last = Rings.points((Rings.COUNT - 1).toFloat(), Offset(0f, 0f), inner, wide).map { it.getDistance() }.average()
        assertTrue("last ring $last", last >= 868f * 2.625f)
        // Upright they already cross it: nothing changes.
        assertEquals(1f, Rings.spread(inner, reach = 365f * 2.625f), 0f)
    }

    @Test
    fun `every part of a ring keeps moving outwards the whole way, none turns back as it nears the edge`() {
        val centre = Offset(0f, 0f)
        // Upright (rings as designed) and on its side (stretched to reach the far edge).
        listOf(1f, Rings.spread(79f, reach = 868f * 2.625f)).forEach { spread ->
            var before = Rings.points(0f, centre, 79f, spread).map { it.getDistance() }
            var u = 0.05f
            while (u <= Rings.COUNT) {
                val now = Rings.points(u, centre, 79f, spread).map { it.getDistance() }
                now.forEachIndexed { i, r -> assertTrue("spread $spread, step $u, direction $i: ${before[i]} then $r", r > before[i]) }
                before = now
                u += 0.05f
            }
        }
    }
}
