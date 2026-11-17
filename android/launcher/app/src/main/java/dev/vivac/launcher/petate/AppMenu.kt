package dev.vivac.launcher.petate

/** A shortcut an app publishes (e.g. "Nuevo chat"), as the launcher shows it. */
data class AppShortcut(val id: String, val label: String)

sealed interface MenuEntry {
    data class Shortcut(val shortcut: AppShortcut) : MenuEntry
    /** "Poner en el dock" or "Quitar del dock", depending on [inDock]. */
    data class Dock(val inDock: Boolean) : MenuEntry

    /** "Fijar en el campamento" or "Quitar del campamento", depending on [pinned]. */
    data class Pin(val pinned: Boolean) : MenuEntry
    /** "Ocultar del petate" or "Mostrar en el petate", depending on [hidden]. */
    data class Hide(val hidden: Boolean) : MenuEntry
    data object Info : MenuEntry
    data object Uninstall : MenuEntry
}

/** What a long press on an app offers. */
object AppMenu {
    private const val MAX_SHORTCUTS = 4

    /** [inDock] and [pinned] are null where the toggle does not apply. */
    fun build(
        shortcuts: List<AppShortcut>,
        isSystem: Boolean,
        inDock: Boolean? = null,
        pinned: Boolean? = null,
        hidden: Boolean? = null,
    ): List<MenuEntry> =
        shortcuts.filter { it.label.isNotBlank() }.take(MAX_SHORTCUTS).map { MenuEntry.Shortcut(it) } +
            listOfNotNull(inDock?.let { MenuEntry.Dock(it) }, pinned?.let { MenuEntry.Pin(it) }, hidden?.let { MenuEntry.Hide(it) }) +
            MenuEntry.Info +
            (if (isSystem) emptyList() else listOf(MenuEntry.Uninstall))
}
