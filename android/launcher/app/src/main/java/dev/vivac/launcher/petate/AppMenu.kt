package dev.vivac.launcher.petate

/** A shortcut an app publishes (e.g. "Nuevo chat"), as the launcher shows it. */
data class AppShortcut(val id: String, val label: String)

sealed interface MenuEntry {
    data class Shortcut(val shortcut: AppShortcut) : MenuEntry
    data object Info : MenuEntry
    data object Uninstall : MenuEntry
}

/** What a long press on an app offers. */
object AppMenu {
    private const val MAX_SHORTCUTS = 4

    fun build(shortcuts: List<AppShortcut>, isSystem: Boolean): List<MenuEntry> =
        shortcuts.filter { it.label.isNotBlank() }.take(MAX_SHORTCUTS).map { MenuEntry.Shortcut(it) } +
            MenuEntry.Info +
            (if (isSystem) emptyList() else listOf(MenuEntry.Uninstall))
}
