package dev.vivac.launcher.apps

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CalendarContract
import android.provider.ContactsContract
import dev.vivac.launcher.core.CalendarEvent
import dev.vivac.launcher.core.Contact
import dev.vivac.launcher.core.Directory

/** Adapter: contacts and calendars through Android's providers, only with the permissions you granted. */
class AndroidDirectory(private val activity: Activity) : Directory {
    private val resolver get() = activity.contentResolver

    override fun canReadContacts() = granted(Manifest.permission.READ_CONTACTS)
    override fun canReadCalendar() = granted(Manifest.permission.READ_CALENDAR)

    override fun contacts(query: String): List<Contact> = runCatching {
        val uri = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI, Uri.encode(query))
        val columns = arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME_PRIMARY, ContactsContract.Contacts.LOOKUP_KEY)
        resolver.query(uri, columns, null, null, ContactsContract.Contacts.DISPLAY_NAME_PRIMARY)?.use { c ->
            buildList { while (c.moveToNext() && size < MAX) add(Contact(c.getLong(0), c.getString(1).orEmpty(), c.getString(2).orEmpty())) }
        }.orEmpty()
    }.getOrDefault(emptyList())

    override fun events(query: String): List<CalendarEvent> = runCatching {
        val now = System.currentTimeMillis()
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, now)
            ContentUris.appendId(it, now + HORIZON_MS)
        }.build()
        val columns = arrayOf(CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN)
        resolver.query(uri, columns, "${CalendarContract.Instances.TITLE} LIKE ?", arrayOf("%$query%"), "${CalendarContract.Instances.BEGIN} ASC")?.use { c ->
            buildList { while (c.moveToNext() && size < MAX) add(CalendarEvent(c.getLong(0), c.getString(1).orEmpty(), c.getLong(2))) }
        }.orEmpty()
    }.getOrDefault(emptyList())

    override fun openContact(contact: Contact) =
        start(Intent(Intent.ACTION_VIEW, ContactsContract.Contacts.getLookupUri(contact.id, contact.lookup)))

    override fun openEvent(event: CalendarEvent) =
        start(Intent(Intent.ACTION_VIEW, ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, event.id)))

    override fun askContacts() = activity.requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), REQ_CONTACTS)
    override fun askCalendar() = activity.requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), REQ_CALENDAR)

    private fun granted(permission: String) = activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun start(intent: Intent) {
        runCatching { activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    companion object {
        const val REQ_CONTACTS = 7006
        const val REQ_CALENDAR = 7007
        private const val MAX = 10
        /** Events up to half a year ahead. */
        private const val HORIZON_MS = 183L * 24 * 60 * 60 * 1000
    }
}
