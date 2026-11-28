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
        assertEquals(true, AndroidNotices.setQuiet(true))
        AndroidNotices.quiet()
        service.onListenerDisconnected()
        assertEquals(emptyList<dev.vivac.launcher.avisos.Aviso>(), AndroidNotices.live.value)
        assertEquals(false, AndroidNotices.quiet())
        assertEquals(false, AndroidNotices.setQuiet(true))
        // Without a connected listener the shade's buttons do nothing.
        AndroidNotices.open("x"); AndroidNotices.dismiss("x"); AndroidNotices.act("x", 0)
        assertEquals(false, AndroidNotices.reply("x", "y"))
    }

    @Test
    fun `the shade's notices carry who wrote, the picture, the detail, the chat's messages and the app's own buttons`() {
        val service = Robolectric.buildService(DotsListener::class.java).create().get()
        val shadow = shadowOf(service)
        val face = android.graphics.Bitmap.createBitmap(400, 400, android.graphics.Bitmap.Config.ARGB_8888)
        val photo = android.graphics.Bitmap.createBitmap(2000, 1000, android.graphics.Bitmap.Config.ARGB_8888)
        val read = android.app.PendingIntent.getBroadcast(app, 2, android.content.Intent("x.read").setPackage(app.packageName), android.app.PendingIntent.FLAG_IMMUTABLE)
        val sent = android.app.PendingIntent.getBroadcast(app, 3, android.content.Intent("x.reply").setPackage(app.packageName), android.app.PendingIntent.FLAG_MUTABLE)
        val reply = Notification.Action.Builder(null, "Responder", sent).addRemoteInput(android.app.RemoteInput.Builder("text").build()).build()
        val pic = Notification.Builder(app, "c").setSmallIcon(android.R.drawable.star_on)
            .setContentTitle("Ana").setContentText("una foto").setSubText("Familia")
            .setLargeIcon(android.graphics.drawable.Icon.createWithBitmap(face))
            .setStyle(Notification.BigPictureStyle().bigPicture(photo))
            .addAction(reply).addAction(Notification.Action.Builder(null, "Marcar leído", read).build()).build()
        val luis = android.app.Person.Builder().setName("Luis").build()
        val eva = android.app.Person.Builder().setName("Eva").build()
        val chat = Notification.Builder(app, "c").setSmallIcon(android.R.drawable.star_on).setContentTitle("Grupo")
            .setStyle(Notification.MessagingStyle(luis).setGroupConversation(true).addMessage("hola", 1, luis).addMessage("vale", 2, eva)).build()
        val alone = Notification.Builder(app, "c").setSmallIcon(android.R.drawable.star_on).setContentTitle("Eva")
            .setStyle(Notification.MessagingStyle(luis).addMessage("¿vienes?", 1, eva)).build()
        val mail = Notification.Builder(app, "c").setSmallIcon(android.R.drawable.star_on).setContentTitle("2 correos")
            .setStyle(Notification.InboxStyle().addLine("Factura").addLine("Recibo")).build()
        shadow.addActiveNotification("org.signal", 1, pic)
        shadow.addActiveNotification("org.chat", 2, chat)
        shadow.addActiveNotification("org.one", 3, alone)
        shadow.addActiveNotification("com.mail", 4, mail)
        service.onListenerConnected()
        val avisos = AndroidNotices.live.value.associateBy { it.packageName }
        val ana = avisos.getValue("org.signal")
        assertEquals("Familia", ana.detail)
        assertEquals(listOf("Marcar leído"), ana.actions)
        // Pictures are scaled down to what the shade shows, so a full-size photo does not sit in memory.
        assertEquals(96 to 96, ana.avatar!!.width to ana.avatar!!.height)
        assertEquals(720 to 360, ana.picture!!.width to ana.picture!!.height)
        // A group chat says who wrote each message; a chat with one person does not repeat the name.
        assertEquals("Luis: hola\nEva: vale", avisos.getValue("org.chat").text)
        assertEquals("¿vienes?", avisos.getValue("org.one").text)
        assertEquals("Factura\nRecibo", avisos.getValue("com.mail").text)
        assertEquals(null, avisos.getValue("com.mail").picture)
        AndroidNotices.act(ana.key, 0)
        AndroidNotices.act(ana.key, 7)
        AndroidNotices.act("nope", 0)
        assertEquals(listOf("x.read"), shadowOf(app).broadcastIntents.map { it.action })
        // A notice that has not changed keeps its pictures: they are not decoded again.
        service.onNotificationPosted(null)
        assertEquals(true, ana.picture === AndroidNotices.live.value.single { it.packageName == "org.signal" }.picture)
        service.onListenerDisconnected()
    }

    @Test
    fun `a media notification becomes what is playing, with controls, and goes when access is lost`() {
        val service = Robolectric.buildService(DotsListener::class.java).create().get()
        val session = android.media.session.MediaSession(app, "test")
        val song = Notification.Builder(app, "c").setSmallIcon(android.R.drawable.star_on)
            .setContentTitle("Canción").setContentText("Grupo")
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken)).build()
        shadowOf(service).addActiveNotification("org.music", 1, song)
        service.onListenerConnected()
        assertEquals(dev.vivac.launcher.core.NowPlaying("Canción", "Grupo", "org.music", playing = false), AndroidNotices.playing.value)
        dev.vivac.launcher.core.Media.entries.forEach(AndroidNotices::media)
        service.onListenerDisconnected()
        assertEquals(null, AndroidNotices.playing.value)
        // Without a listener the buttons do nothing.
        AndroidNotices.media(dev.vivac.launcher.core.Media.TOGGLE)
        session.release()
    }
}
