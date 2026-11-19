package dev.vivac.launcher

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Real fingers on the real camp, which Robolectric cannot give: run on a phone where vivac is the home app and
 * "Pellizcar" is set to "Ver los avisos" in vivac's settings.
 */
@RunWith(AndroidJUnit4::class)
class DeviceGesturesTest {
    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    @Test
    fun aPinchOnTheCampOpensTheNotices() {
        // The run restarts vivac's process: go home until vivac is drawn again.
        repeat(3) {
            device.pressHome()
            if (device.wait(Until.hasObject(By.pkg("dev.vivac.launcher").depth(0)), 5_000)) return@repeat
        }
        val camp = device.wait(Until.findObject(By.descStartsWith("Campamento, página")), 10_000)
        assertNotNull("the camp is on screen", camp)
        camp.pinchClose(0.7f, 800)
        assertTrue("the pinch left the camp", device.wait(Until.gone(By.descStartsWith("Campamento, página")), 3_000))
        device.pressHome()
    }
}
