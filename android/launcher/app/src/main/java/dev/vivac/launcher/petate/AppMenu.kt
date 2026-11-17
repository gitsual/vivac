package dev.vivac.launcher.petate

/** A shortcut an app publishes (e.g. "Nuevo chat"), as the launcher shows it. */
data class AppShortcut(val id: String, val label: String)

sealed interface MenuEntry {
    data class Shortcut(val shortcut: AppShortcut) : MenuEntry
    /** Puts the shortcut itself on a ladera, from the pin beside it in the menu. */
    data class PinShortcut(val shortcut: AppShortcut) : MenuEntry
    /** "Poner en el dock" or "Quitar del dock", depending on [inDock]. */
    /** Where the app sits on the Campamento: dock, pins, or hidden. */
    sealed interface Place : MenuEntry

    data class Dock(val inDock: Boolean) : Place

    /** "Fijar en el campamento" or "Quitar del campamento", depending on [pinned]. */
    data class Pin(val pinned: Boolean) : Place
    /** "Ocultar del petate" or "Mostrar en el petate", depending on [hidden]. */
    /** On a ladera (a home page right of the Campamento), or not yet. */
    data class Ladera(val onLadera: Boolean) : Place
    data class Hide(val hidden: Boolean) : Place
    /** On a shortcut's own menu: take it off its ladera. */
    data class UnpinShortcut(val shortcut: AppShortcut) : Place
    /** "Cambiar el nombre": offered by the sheet for any app, not built into the list. */
    data object Rename : MenuEntry
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
        onLadera: Boolean? = null,
    ): List<MenuEntry> =
        shortcuts.filter { it.label.isNotBlank() }.take(MAX_SHORTCUTS).map { MenuEntry.Shortcut(it) } +
            listOfNotNull(inDock?.let { MenuEntry.Dock(it) }, pinned?.let { MenuEntry.Pin(it) }, onLadera?.let { MenuEntry.Ladera(it) }, hidden?.let { MenuEntry.Hide(it) }) +
            MenuEntry.Info +
            (if (isSystem) emptyList() else listOf(MenuEntry.Uninstall))
}
