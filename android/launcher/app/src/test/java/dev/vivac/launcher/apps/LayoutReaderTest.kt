package dev.vivac.launcher.apps

import android.app.Application
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.core.Launcher3Row
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf

@RunWith(AndroidJUnit4::class)
class LayoutReaderTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()

    /** A Launcher3 database as Nova and Lawnchair keep it, with one app on the first screen. */
    private fun database(): ByteArray {
        val file = java.io.File(app.cacheDir, "made.db").apply { delete() }
        SQLiteDatabase.openOrCreateDatabase(file, null).use { db ->
            db.execSQL("CREATE TABLE favorites (_id INTEGER, title TEXT, intent TEXT, container INTEGER, screen INTEGER, cellX INTEGER, cellY INTEGER, itemType INTEGER)")
            db.execSQL("INSERT INTO favorites VALUES (1, 'Signal', '#Intent;component=org.signal/.Main;end', -100, 0, 2, 1, 0)")
        }
        return file.readBytes().also { file.delete() }
    }

    private fun zipped(name: String, bytes: ByteArray): ByteArray = java.io.ByteArrayOutputStream().also { out ->
        java.util.zip.ZipOutputStream(out).use { zip ->
            zip.putNextEntry(java.util.zip.ZipEntry("preferences.xml")); zip.write("<map/>".toByteArray()); zip.closeEntry()
            zip.putNextEntry(java.util.zip.ZipEntry(name)); zip.write(bytes); zip.closeEntry()
        }
    }.toByteArray()

    private fun uri(name: String, bytes: ByteArray) = android.net.Uri.parse("content://docs/$name").also {
        shadowOf(app.contentResolver).registerInputStream(it, bytes.inputStream())
    }

    private val signal = Launcher3Row(1, -100, 0, 2, 1, 0, 0, "#Intent;component=org.signal/.Main;end", "Signal")

    @Test
    fun `a nova backup, a lawnchair backup or the bare database all give the same rows`() {
        val db = database()
        assertEquals(listOf(signal), LayoutReader.read(app, uri("copia.novabackup", zipped("launcher.db", db))))
        assertEquals(listOf(signal), LayoutReader.read(app, uri("copia.lawnchairbackup", zipped("launcher_4_by_5.db", db))))
        assertEquals(listOf(signal), LayoutReader.read(app, uri("launcher.db", db)))
    }

    @Test
    fun `anything else gives no rows`() {
        assertEquals(emptyList<Launcher3Row>(), LayoutReader.read(app, uri("nota.txt", "hola".toByteArray())))
        assertEquals(emptyList<Launcher3Row>(), LayoutReader.read(app, uri("otro.zip", zipped("nada.txt", "x".toByteArray()))))
    }
}
