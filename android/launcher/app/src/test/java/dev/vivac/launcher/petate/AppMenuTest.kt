package dev.vivac.launcher.petate

import org.junit.Assert.assertEquals
import org.junit.Test

class AppMenuTest {
    private fun s(id: String, label: String) = AppShortcut(id, label)

    @Test
    fun `shortcuts come first, then info and uninstall`() {
        val menu = AppMenu.build(listOf(s("new", "Nuevo chat"), s("cam", "Cámara")), isSystem = false)
        assertEquals(
            listOf(MenuEntry.Shortcut(s("new", "Nuevo chat")), MenuEntry.Shortcut(s("cam", "Cámara")), MenuEntry.Info, MenuEntry.Uninstall),
            menu,
        )
    }

    @Test
    fun `system apps cannot be uninstalled, so that entry is left out`() {
        assertEquals(listOf(MenuEntry.Info), AppMenu.build(emptyList(), isSystem = true))
    }

    @Test
    fun `at most four shortcuts, like the system launcher`() {
        val many = (1..6).map { s("$it", "Atajo $it") }
        val menu = AppMenu.build(many, isSystem = false)
        assertEquals(4, menu.count { it is MenuEntry.Shortcut })
        assertEquals(listOf(MenuEntry.Info, MenuEntry.Uninstall), menu.takeLast(2))
    }

    @Test
    fun `home toggles sit between shortcuts and info, worded for the current state`() {
        val menu = AppMenu.build(listOf(s("n", "Nuevo")), isSystem = true, inDock = true, pinned = false)
        assertEquals(
            listOf(MenuEntry.Shortcut(s("n", "Nuevo")), MenuEntry.Dock(inDock = true), MenuEntry.Pin(pinned = false), MenuEntry.Info),
            menu,
        )
    }

    @Test
    fun `shortcuts with blank labels are skipped`() {
        val menu = AppMenu.build(listOf(s("a", " "), s("b", "Buscar")), isSystem = true)
        assertEquals(listOf(MenuEntry.Shortcut(s("b", "Buscar")), MenuEntry.Info), menu)
    }

    @Test
    fun `hide toggle comes right before info`() {
        val menu = AppMenu.build(emptyList(), isSystem = true, inDock = false, pinned = false, hidden = true)
        assertEquals(listOf(MenuEntry.Dock(false), MenuEntry.Pin(false), MenuEntry.Hide(hidden = true), MenuEntry.Info), menu)
    }

    @Test
    fun `the ladera toggle sits after the pin, worded for where the app is`() {
        val menu = AppMenu.build(emptyList(), isSystem = true, inDock = false, pinned = false, onLadera = true, hidden = false)
        assertEquals(listOf(MenuEntry.Dock(false), MenuEntry.Pin(false), MenuEntry.Ladera(true), MenuEntry.Hide(false), MenuEntry.Info), menu)
    }
}
