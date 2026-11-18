package dev.vivac.launcher.widgets

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WidgetColorsTest {
    @Test
    fun `widgets get vivac's colours for every tone of Android's five ramps`() {
        val colours = WidgetColors.resources()
        assertEquals(5 * 13, colours.size())
        assertEquals(0xFFE1777D.toInt(), colours.get(android.R.color.system_accent1_400))
        assertEquals(0xFF2D1F2D.toInt(), colours.get(android.R.color.system_neutral1_900))
        assertEquals(0xFFE8D5AB.toInt(), colours.get(android.R.color.system_neutral1_100))
        assertEquals(0xFF6CA4B1.toInt(), colours.get(android.R.color.system_accent2_400))
    }

    @Test
    fun `the tint takes a widget's black to vivac's card and its white to vivac's paper, alpha untouched`() {
        val m = WidgetColors.tint().array
        fun channel(row: Int, v: Float) = m[row * 5] * v + m[row * 5 + 1] * v + m[row * 5 + 2] * v + m[row * 5 + 4]
        assertEquals(0x2D.toFloat(), channel(0, 0f), 0.5f)
        assertEquals(0x1F.toFloat(), channel(1, 0f), 0.5f)
        assertEquals(0xE8.toFloat(), channel(0, 255f), 0.5f)
        assertEquals(0xAB.toFloat(), channel(2, 255f), 0.5f)
        assertEquals(1f, m[18])
    }
}
