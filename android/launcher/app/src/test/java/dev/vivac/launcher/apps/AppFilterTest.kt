package dev.vivac.launcher.apps

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppFilterTest {
    @Test
    fun `an icon pack's appfilter maps each activity to its drawable, skipping broken items`() {
        val xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <resources>
              <iconback img1="iconback" />
              <item component="ComponentInfo{org.signal/org.signal.Main}" drawable="signal" />
              <item component="ComponentInfo{app.organicmaps/app.organicmaps.SplashActivity}" drawable="organic_maps"/>
              <item component=":LAUNCHER_ACTION_APP_DRAWER" drawable="drawer" />
              <item component="ComponentInfo{broken" drawable="x" />
              <item drawable="nothing" />
              <calendar component="ComponentInfo{a.cal/a.cal.Main}" prefix="calendar_" />
            </resources>
        """.trimIndent()
        val filter = AppFilter.parse(xml.byteInputStream())
        assertEquals("signal", filter["org.signal/org.signal.Main"])
        assertEquals("organic_maps", filter["app.organicmaps/app.organicmaps.SplashActivity"])
        assertEquals(2, filter.size)
        assertEquals(emptyMap<String, String>(), AppFilter.parse("not xml <".byteInputStream()))
    }
}
