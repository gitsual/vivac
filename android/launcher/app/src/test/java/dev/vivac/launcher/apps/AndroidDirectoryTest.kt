package dev.vivac.launcher.apps

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.provider.ContactsContract
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.core.CalendarEvent
import dev.vivac.launcher.core.Contact
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
}
