package dev.vivac.launcher.apps

import android.app.Notification
import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf

@RunWith(AndroidJUnit4::class)
class DotsListenerTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()

    private fun notice(ongoing: Boolean = false, summary: Boolean = false) = Notification.Builder(app, "c")
        .setSmallIcon(android.R.drawable.star_on)
        .setOngoing(ongoing)
        .setGroup("g")
        .setGroupSummary(summary)
        .build()

    @Test
    fun `active notifications become dots, ongoing ones and summaries do not, and losing access clears them`() {
        val service = Robolectric.buildService(DotsListener::class.java).create().get()
        val shadow = shadowOf(service)
        shadow.addActiveNotification("org.signal", 1, notice())
        shadow.addActiveNotification("com.music", 2, notice(ongoing = true))
        shadow.addActiveNotification("com.mail", 3, notice(summary = true))
        service.onListenerConnected()
        assertEquals(setOf("org.signal"), Dots.live.value)
        shadow.addActiveNotification("com.mail", 4, notice())
        service.onNotificationPosted(null)
        assertEquals(setOf("org.signal", "com.mail"), Dots.live.value)
        service.onNotificationRemoved(null)
        service.onListenerDisconnected()
        assertEquals(emptySet<String>(), Dots.live.value)
    }
}
