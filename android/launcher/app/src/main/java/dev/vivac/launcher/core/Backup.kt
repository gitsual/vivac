package dev.vivac.launcher.core

import dev.vivac.launcher.campamento.Placed
import dev.vivac.launcher.campamento.WidgetBoard
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * The camp to a file and back: a first line that names it, then one `key=value` per setting (URL-encoded).
 * Widgets are left out: their ids belong to this phone's widget host, and the apps must be asked again anyway.
 */
object Backup {
    private const val HEADER = "vivac-campamento 1"
    private val KEYS = listOf(
        Launcher.KEY_DOCK, Launcher.KEY_PINNED, Launcher.KEY_HIDDEN, Launcher.KEY_WIDGETS, Launcher.KEY_RECENT,
        Launcher.KEY_NAMES, Launcher.KEY_LOCKED, Launcher.KEY_DOUBLE_TAP, Launcher.KEY_WALLPAPER, Launcher.KEY_VEIL, Launcher.KEY_BLUR_SHEETS, Launcher.KEY_BLUR_WALLPAPER,
        Launcher.KEY_COLUMNS, Launcher.KEY_LABELS, Launcher.KEY_COUNTS, Launcher.KEY_SWIPE_UP, Launcher.KEY_SWIPE_DOWN, Launcher.KEY_SWIPE_UP_APP, Launcher.KEY_SWIPE_DOWN_APP,
        Launcher.KEY_ICONS, Launcher.KEY_ICON_PACK, Launcher.KEY_ICON_FOR, Launcher.KEY_CATEGORY_FOR,
    )

    private val DEFAULTS = mapOf(
        Launcher.KEY_NAMES to "", Launcher.KEY_LOCKED to "0", Launcher.KEY_DOUBLE_TAP to "0", Launcher.KEY_WALLPAPER to "0", Launcher.KEY_VEIL to "MEDIO", Launcher.KEY_BLUR_SHEETS to "1", Launcher.KEY_BLUR_WALLPAPER to "0",
        Launcher.KEY_COLUMNS to "4", Launcher.KEY_LABELS to "1", Launcher.KEY_COUNTS to "0",
        Launcher.KEY_SWIPE_UP to "PETATE", Launcher.KEY_SWIPE_DOWN to "NOTIFICATIONS",
        Launcher.KEY_ICONS to "GLYPHS", Launcher.KEY_ICON_PACK to "", Launcher.KEY_ICON_FOR to "", Launcher.KEY_CATEGORY_FOR to "",
    )

    fun export(store: Store): String = buildString {
        append(HEADER).append('\n')
        KEYS.forEach { key ->
            // Choices you never touched still go in, so restoring undoes what you changed since.
            var value = store.get(key) ?: DEFAULTS[key] ?: return@forEach
            if (key == Launcher.KEY_WIDGETS) value = WidgetBoard(WidgetBoard.decode(value).items.filterNot { it is Placed }).encode()
            append(key).append('=').append(URLEncoder.encode(value, "UTF-8")).append('\n')
        }
    }

    /** Writes the copy into [store], keeping this phone's widgets; false (and nothing written) if it is not a copy. */
    fun restore(text: String, store: Store): Boolean {
        val lines = text.lines()
        if (lines.firstOrNull()?.trim() != HEADER) return false
        val values = lines.drop(1).mapNotNull { line ->
            val (key, value) = line.split("=", limit = 2).takeIf { it.size == 2 && it[0] in KEYS } ?: return@mapNotNull null
            key to URLDecoder.decode(value, "UTF-8")
        }.toMap().toMutableMap()
        values[Launcher.KEY_WIDGETS]?.let { saved ->
            val here = WidgetBoard.decode(store.get(Launcher.KEY_WIDGETS)).items.filterIsInstance<Placed>()
            values[Launcher.KEY_WIDGETS] = WidgetBoard(here + WidgetBoard.decode(saved).items).encode()
        }
        store.put(values)
        return true
    }
}
