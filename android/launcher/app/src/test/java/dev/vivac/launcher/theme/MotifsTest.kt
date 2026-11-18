package dev.vivac.launcher.theme

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MotifsTest {
    @Test
    fun `the rings are centred on the given point, the smallest one just around it`() {
        val (s, x, y) = ringsAround(Offset(900f, 200f), innerRadius = 80f)
        // The summit lands on the point...
        assertEquals(900f, x + Rings.SUMMIT.x * s, 0.5f)
        assertEquals(200f, y + Rings.SUMMIT.y * s, 0.5f)
        // ...and the smallest ring's radius is the one asked for.
        assertEquals(80f, Rings.INNER_RADIUS * s, 0.5f)
    }

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
}
