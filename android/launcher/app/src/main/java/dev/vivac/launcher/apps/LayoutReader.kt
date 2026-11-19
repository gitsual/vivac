package dev.vivac.launcher.apps

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import dev.vivac.launcher.core.Launcher3Row

/**
 * Reads the home layout out of another launcher's backup: a Nova `.novabackup` or a Lawnchair backup (zips that
 * hold a Launcher3 database) or the database itself. The file is copied to the cache, read only, then deleted.
 */
object LayoutReader {
    fun read(context: Context, uri: Uri): List<Launcher3Row> {
        val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
        val db = if (bytes.size > 1 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()) databaseIn(bytes) else bytes
        if (db == null || !db.decodeToString(0, minOf(15, db.size)).startsWith("SQLite format")) return emptyList()
        val file = java.io.File.createTempFile("import", ".db", context.cacheDir)
        return try {
            file.writeBytes(db)
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use(::rows)
        } finally {
            file.delete()
        }
    }

    /** The first `.db` inside the zip. */
    private fun databaseIn(zip: ByteArray): ByteArray? = java.util.zip.ZipInputStream(zip.inputStream()).use { z ->
        generateSequence { z.nextEntry }.firstOrNull { it.name.endsWith(".db") }?.let { z.readBytes() }
    }

    private fun rows(db: SQLiteDatabase): List<Launcher3Row> = runCatching {
        db.rawQuery("SELECT * FROM favorites", null).use { c ->
            val col = { name: String -> c.getColumnIndex(name) }
            val int = { name: String -> col(name).let { if (it < 0) 0 else c.getInt(it) } }
            val text = { name: String -> col(name).let { if (it < 0 || c.isNull(it)) null else c.getString(it) } }
            buildList {
                while (c.moveToNext()) add(
                    Launcher3Row(
                        id = c.getLong(col("_id")), container = c.getLong(col("container")), screen = int("screen"),
                        cellX = int("cellX"), cellY = int("cellY"), rank = int("rank"), itemType = int("itemType"),
                        intent = text("intent"), title = text("title"),
                    ),
                )
            }
        }
    }.getOrDefault(emptyList())
}
