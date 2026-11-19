package dev.vivac.launcher.apps

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.provider.ContactsContract
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.core.CalendarEvent
import dev.vivac.launcher.core.Contact
import dev.vivac.launcher.core.FoundFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf

@RunWith(AndroidJUnit4::class)
class AndroidDirectoryTest {
    private val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    private val dir = AndroidDirectory(activity)

    @Test
    fun `nothing is read without android's permission, which vivac asks for`() {
        assertFalse(dir.canReadContacts())
        assertFalse(dir.canReadCalendar())
        dir.askContacts()
        assertEquals(listOf(Manifest.permission.READ_CONTACTS), shadowOf(activity).lastRequestedPermission.requestedPermissions.toList())
        dir.askCalendar()
        assertEquals(listOf(Manifest.permission.READ_CALENDAR), shadowOf(activity).lastRequestedPermission.requestedPermissions.toList())
        shadowOf(activity).grantPermissions(Manifest.permission.READ_CONTACTS, Manifest.permission.READ_CALENDAR)
        assertTrue(dir.canReadContacts())
        assertTrue(dir.canReadCalendar())
    }

    @Test
    fun `providers that answer nothing give empty results, and opening goes to the contact or event`() {
        assertEquals(emptyList<Contact>(), dir.contacts("ana"))
        assertEquals(emptyList<CalendarEvent>(), dir.events("cena"))
        dir.openContact(Contact(1, "Ana", "lk"))
        val contact = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, contact.action)
        assertEquals(ContactsContract.Contacts.getLookupUri(1, "lk"), contact.data)
        dir.openEvent(CalendarEvent(5, "Cena", 0))
        assertEquals("content://com.android.calendar/events/5", shadowOf(activity).nextStartedActivity.data.toString())
    }

    @Test
    fun `photos, videos and music are searched only with media permission, and open in their own app`() {
        assertFalse(dir.canReadFiles())
        dir.askFiles()
        assertEquals(
            listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_AUDIO),
            shadowOf(activity).lastRequestedPermission.requestedPermissions.toList(),
        )
        shadowOf(activity).grantPermissions(Manifest.permission.READ_MEDIA_IMAGES)
        assertTrue(dir.canReadFiles())
        assertEquals(emptyList<FoundFile>(), dir.files("playa"))
        dir.openFile(FoundFile(9, "playa.jpg", FoundFile.Kind.FOTO))
        val open = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, open.action)
        assertEquals("content://media/external/images/media/9", open.data.toString())
        assertTrue(open.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        dir.openFile(FoundFile(3, "a.mp4", FoundFile.Kind.VIDEO))
        assertEquals("content://media/external/video/media/3", shadowOf(activity).nextStartedActivity.data.toString())
        dir.openFile(FoundFile(4, "a.mp3", FoundFile.Kind.AUDIO))
        assertEquals("content://media/external/audio/media/4", shadowOf(activity).nextStartedActivity.data.toString())
    }
}
