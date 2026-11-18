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
        assertEquals(setOf("org.signal", "com.mail"), Dots.liveCounts.value.keys)
        service.onNotificationRemoved(null)
        service.onListenerDisconnected()
        assertEquals(emptySet<String>(), Dots.live.value)
    }

    @Test
    fun `the shade's notices carry title, text and whether they take a reply, and act on the real notification`() {
        val service = Robolectric.buildService(DotsListener::class.java).create().get()
        val shadow = shadowOf(service)
        val sent = android.app.PendingIntent.getBroadcast(app, 0, android.content.Intent("x.reply").setPackage(app.packageName), android.app.PendingIntent.FLAG_MUTABLE)
        val open = android.app.PendingIntent.getActivity(app, 1, android.content.Intent("x.open"), android.app.PendingIntent.FLAG_IMMUTABLE)
        val reply = Notification.Action.Builder(null, "Responder", sent).addRemoteInput(android.app.RemoteInput.Builder("text").build()).build()
        val chat = Notification.Builder(app, "c").setSmallIcon(android.R.drawable.star_on)
            .setContentTitle("Ana").setContentText("¿vienes?").addAction(reply).setContentIntent(open).setAutoCancel(true).build()
        shadow.addActiveNotification("org.signal", 1, chat)
        shadow.addActiveNotification("com.mail", 2, notice())
        service.onListenerConnected()
        val avisos = AndroidNotices.live.value
        val ana = avisos.single { it.packageName == "org.signal" }
        assertEquals("Ana" to "¿vienes?", ana.title to ana.text)
        assertEquals(true, ana.canReply)
        assertEquals(false, avisos.single { it.packageName == "com.mail" }.canReply)
        assertEquals(true, AndroidNotices.reply(ana.key, "voy"))
        assertEquals(false, AndroidNotices.reply("nope", "voy"))
        assertEquals(false, AndroidNotices.reply(avisos.single { it.packageName == "com.mail" }.key, "voy"))
        AndroidNotices.open(ana.key)
        AndroidNotices.open("nope")
        AndroidNotices.dismiss(ana.key)
        AndroidNotices.dismissAll()
        service.onListenerDisconnected()
        assertEquals(emptyList<dev.vivac.launcher.avisos.Aviso>(), AndroidNotices.live.value)
        // Without a connected listener the shade's buttons do nothing.
        AndroidNotices.open("x"); AndroidNotices.dismiss("x"); AndroidNotices.dismissAll()
        assertEquals(false, AndroidNotices.reply("x", "y"))
    }
}
