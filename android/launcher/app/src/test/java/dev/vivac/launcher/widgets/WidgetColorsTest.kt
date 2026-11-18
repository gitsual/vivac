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
}
