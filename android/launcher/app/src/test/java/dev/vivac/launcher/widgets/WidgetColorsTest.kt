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
    fun `the tint takes a widget's dark background to vivac's card and its white to vivac's paper, alpha untouched`() {
        val m = WidgetColors.tint().array
        fun channel(row: Int, v: Float) = m[row * 5] * v + m[row * 5 + 1] * v + m[row * 5 + 2] * v + m[row * 5 + 4]
        // Pure black goes to vivac's night, so a widget's own dark grey (#1F1F1F, Material's) lands near the card.
        assertEquals(0x18.toFloat(), channel(0, 0f), 0.5f)
        assertEquals(0x13.toFloat(), channel(1, 0f), 0.5f)
        assertEquals(0x2D.toFloat(), channel(0, 0x1F.toFloat()), 6f)
        assertEquals(0xE8.toFloat(), channel(0, 255f), 0.5f)
        assertEquals(0xAB.toFloat(), channel(2, 255f), 0.5f)
        assertEquals(1f, m[18])
    }
}
