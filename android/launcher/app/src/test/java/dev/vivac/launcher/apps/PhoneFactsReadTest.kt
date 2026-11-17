package dev.vivac.launcher.apps

import android.app.Application
import android.os.BatteryManager
import android.os.Environment
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.campamento.PhoneFacts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowStatFs

@RunWith(AndroidJUnit4::class)
class PhoneFactsReadTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()

    @Test
    fun `facts are read from the disk and the battery`() {
        // Robolectric's StatFs uses 4096-byte blocks: 2.5M blocks ≈ 10 GB.
        ShadowStatFs.registerStats(Environment.getDataDirectory(), 2_500_000, 1_000_000, 1_000_000)
        shadowOf(app.getSystemService(BatteryManager::class.java)).apply {
            setIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY, 64)
            setIsCharging(true)
        }
        val facts = PhoneFacts.read(app)
        assertEquals(4L, facts.freeGb)
        assertEquals(10L, facts.totalGb)
        assertEquals(64, facts.batteryPercent)
        assertTrue(facts.charging)
    }
}
