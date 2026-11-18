package dev.vivac.launcher.avisos

/**
 * A notification as vivac's own shade shows it. Its title and text live only in memory while the shade can show
 * them; vivac never stores them.
 */
data class Aviso(
    val key: String,
    val packageName: String,
    val title: String,
    val text: String,
    /** When the app posted it, in milliseconds since the epoch. */
    val postedAt: Long,
    val ongoing: Boolean,
    val clearable: Boolean,
    /** A group's summary, which repeats what the notices in the group already say. */
    val summary: Boolean,
    /** Whether it takes a written reply (a chat's "Reply"). */
    val canReply: Boolean,
    /** The app's name as Android gives it, for apps (the system's) that are not on the home screen. */
    val appLabel: String = "",
)

/** One app's notices in the shade, newest first. */
data class AvisoGroup(val packageName: String, val avisos: List<Aviso>)

object Avisos {
    /**
     * The shade's contents: notices grouped by app, newest first, apps with only ongoing notices (music, a
     * download) after the rest. Group summaries and notices with nothing to read are left out.
     */
    fun shelf(all: List<Aviso>): List<AvisoGroup> =
        all.filter { !it.summary && (it.title.isNotBlank() || it.text.isNotBlank()) }
            .groupBy { it.packageName }
            .map { (pkg, avisos) -> AvisoGroup(pkg, avisos.sortedByDescending { it.postedAt }) }
            .sortedWith(compareBy<AvisoGroup> { g -> g.avisos.all { it.ongoing } }.thenByDescending { it.avisos.first().postedAt })

    fun anyClearable(all: List<Aviso>): Boolean = all.any { it.clearable }

    /** How long ago, as people say it: ahora, hace 5 min, hace 2 h, ayer, hace 3 d. */
    fun ago(postedAt: Long, now: Long): String {
        val minutes = (now - postedAt).coerceAtLeast(0) / 60_000
        return when {
            minutes < 1 -> "ahora"
            minutes < 60 -> "hace $minutes min"
            minutes < 24 * 60 -> "hace ${minutes / 60} h"
            minutes < 48 * 60 -> "ayer"
            else -> "hace ${minutes / (24 * 60)} d"
        }
    }
}
