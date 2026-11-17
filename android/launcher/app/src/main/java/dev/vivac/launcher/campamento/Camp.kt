package dev.vivac.launcher.campamento

import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** The small mono "cota" above the Campamento title: `lun 16 nov · 22:49`. */
object Stamp {
    private val spanish = Locale.forLanguageTag("es-ES")
    private val day = DateTimeFormatter.ofPattern("EEE d MMM", spanish)
    private val time = DateTimeFormatter.ofPattern("HH:mm", spanish)

    fun format(now: LocalDateTime): String {
        val date = now.format(day).replace(".", "").lowercase(spanish)
        return "$date · ${now.format(time)}"
    }
}

/** One place in the dock: an app, or the door to the Petate. */
sealed interface DockSlot {
    data class App(val packageName: String) : DockSlot
    data object Petate : DockSlot
}

object Dock {
    /** Favourites in order of preference; Signal goes before WhatsApp when both exist. */
    private val favourites = listOf(
        "com.termux",
        "org.thoughtcrime.securesms",
        "com.whatsapp",
        "app.vanadium.browser",
        "com.tailscale.ipn",
    )
    private const val APP_SLOTS = 4

    /** Your chosen dock when you have one, else the first installed favourites; the Petate always closes it. */
    fun pick(installed: Set<String>, chosen: List<String> = emptyList()): List<DockSlot> {
        val source = chosen.ifEmpty { favourites }
        return source.filter { it in installed }.take(APP_SLOTS).map { DockSlot.App(it) } + DockSlot.Petate
    }
}
