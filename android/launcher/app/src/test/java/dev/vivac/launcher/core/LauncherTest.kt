package dev.vivac.launcher.core

import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.petate.AppShortcut
import dev.vivac.launcher.petate.MenuEntry
import dev.vivac.launcher.widgets.WidgetOption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LauncherTest {
    private val termux = InstalledApp("Termux", "com.termux", false)
    private val signal = InstalledApp("Signal", "org.thoughtcrime.securesms", false)
    private val maps = InstalledApp("Organic Maps", "app.organicmaps", false)
    private val settings = InstalledApp("Ajustes", "com.android.settings", true)
    private val clock = WidgetOption("clock/Clock", "Reloj", "Reloj", "clock", "2 × 2")

    private val source = FakeSource(listOf(termux, signal, maps, settings))
    private val store = FakeStore()
    private val actions = FakeActions()
    private val widgets = FakeWidgets()
    private fun launcher() = Launcher(source, store, actions, widgets).also { it.refresh() }

    @Test
    fun `it starts on the camp with the default dock of installed favourites`() {
        val l = launcher()
        assertEquals(Screen.CAMPAMENTO, l.screen)
        assertEquals(listOf("com.termux", "org.thoughtcrime.securesms"), l.shownDock())
    }

    @Test
    fun `opening the petate from the search pill asks for the keyboard, home brings you back`() {
        val l = launcher()
        l.openPetate(search = true)
        assertEquals(Screen.PETATE, l.screen)
        assertTrue(l.focusSearch)
        l.onHomePressed()
        assertEquals(Screen.CAMPAMENTO, l.screen)
    }

    @Test
    fun `opening an app from the petate returns to the camp`() {
        val l = launcher()
        l.openPetate(search = false)
        l.openFromPetate("app.organicmaps")
        assertEquals(listOf("open:app.organicmaps"), actions.calls)
        assertEquals(Screen.CAMPAMENTO, l.screen)
    }

    @Test
    fun `the menu lists shortcuts and the toggles for the current state`() {
        actions.shortcuts = mapOf("com.termux" to listOf(AppShortcut("s", "Sesión")))
        val l = launcher()
        l.openMenu("com.termux")
        val menu = l.menu!!
        assertEquals(termux, menu.app)
        assertEquals(
            listOf(MenuEntry.Shortcut(AppShortcut("s", "Sesión")), MenuEntry.Dock(true), MenuEntry.Pin(false), MenuEntry.Hide(false), MenuEntry.Info, MenuEntry.Uninstall),
            menu.entries,
        )
    }

    @Test
    fun `a menu for an app that is gone does not open`() {
        val l = launcher()
        l.openMenu("not.there")
        assertNull(l.menu)
    }

    @Test
    fun `picking dock, pin and hide changes the layout and stores it`() {
        val l = launcher()
        l.openMenu("app.organicmaps"); l.pick(MenuEntry.Dock(false))
        assertEquals(listOf("com.termux", "org.thoughtcrime.securesms", "app.organicmaps"), l.home.dock)
        l.openMenu("app.organicmaps"); l.pick(MenuEntry.Pin(false))
        l.openMenu("com.termux"); l.pick(MenuEntry.Hide(false))
        assertNull(l.menu)
        assertEquals(listOf("org.thoughtcrime.securesms", "app.organicmaps"), l.home.dock)
        assertEquals("app.organicmaps", store.values["pinned"])
        assertEquals("com.termux", store.values["hidden"])
        assertFalse(termux in l.visibleApps())
    }

    @Test
    fun `a refused change is said out loud and changes nothing`() {
        store.values["dock"] = "a,b,c,com.termux"
        source.apps = source.apps + listOf("a", "b", "c").map { InstalledApp(it, it, false) }
        val l = launcher()
        l.openMenu("app.organicmaps"); l.pick(MenuEntry.Dock(false))
        assertEquals(listOf("say:El dock ya tiene 4 apps: quita una primero."), actions.calls)
    }

    @Test
    fun `shortcut, info and uninstall entries hand over to Android`() {
        val l = launcher()
        l.openMenu("com.termux"); l.pick(MenuEntry.Shortcut(AppShortcut("s", "Sesión")))
        l.openMenu("com.termux"); l.pick(MenuEntry.Info)
        l.openMenu("com.termux"); l.pick(MenuEntry.Uninstall)
        assertEquals(listOf("shortcut:com.termux/s", "info:com.termux", "uninstall:com.termux"), actions.calls)
    }

    @Test
    fun `layout is read back from storage and uninstalled apps are forgotten`() {
        store.values += mapOf("dock" to "app.organicmaps,gone", "pinned" to "gone,com.termux", "hidden" to "gone")
        val l = launcher()
        assertEquals(listOf("app.organicmaps"), l.home.dock)
        assertEquals(listOf("com.termux"), l.home.pinned)
        assertEquals("app.organicmaps", store.values["dock"])
    }

    @Test
    fun `an empty app list right after boot never wipes the layout`() {
        store.values["dock"] = "app.organicmaps"
        source.apps = emptyList()
        val l = launcher()
        assertEquals(listOf("app.organicmaps"), l.home.dock)
    }

    @Test
    fun `a widget Android already allows is placed straight away`() {
        widgets.offered = listOf(clock)
        val l = launcher()
        l.openCampMenu()
        l.showPicker()
        assertFalse(l.campMenu)
        assertEquals(listOf(clock), l.picker)
        l.addWidget(clock)
        assertNull(l.picker)
        assertEquals(listOf(1), l.board.ids)
        assertEquals("1", store.values["widgets"])
    }

    @Test
    fun `a widget needing permission waits for the bind dialog, then its configuration`() {
        widgets.allowed = false
        widgets.configurable = setOf(clock.key)
        val l = launcher()
        l.addWidget(clock)
        assertEquals(listOf("askBind:1"), widgets.calls)
        widgets.accept(1)
        l.onWidgetResult(WidgetStep.BIND, ok = true)
        assertEquals(listOf("askBind:1", "configure:1"), widgets.calls)
        assertTrue(l.board.ids.isEmpty())
        l.onWidgetResult(WidgetStep.CONFIGURE, ok = true)
        assertEquals(listOf(1), l.board.ids)
        assertEquals(-1, l.pendingWidget)
    }

    @Test
    fun `a cancelled bind or configuration frees the widget id`() {
        widgets.allowed = false
        val l = launcher()
        l.addWidget(clock)
        l.onWidgetResult(WidgetStep.BIND, ok = false)
        assertEquals(listOf("askBind:1", "delete:1"), widgets.calls)
        assertTrue(l.board.ids.isEmpty())
        assertEquals(-1, l.pendingWidget)
    }

    @Test
    fun `a stray result with nothing pending is ignored`() {
        val l = launcher()
        l.onWidgetResult(WidgetStep.CONFIGURE, ok = true)
        assertTrue(l.board.ids.isEmpty())
        assertTrue(widgets.calls.isEmpty())
    }

    @Test
    fun `the pending widget survives the activity being recreated`() {
        widgets.allowed = false
        val l = launcher()
        l.addWidget(clock)
        val again = Launcher(source, store, actions, widgets, pendingWidget = l.pendingWidget).also { it.refresh() }
        widgets.accept(1)
        again.onWidgetResult(WidgetStep.BIND, ok = true)
        assertEquals(listOf(1), again.board.ids)
    }

    @Test
    fun `removing a widget frees it, and widgets whose app is gone are dropped on start`() {
        widgets.placed = mutableMapOf(1 to "a", 2 to "b")
        store.values["widgets"] = "1,2,3"
        val l = launcher()
        assertEquals(listOf(1, 2), l.board.ids)
        l.openCampMenu()
        l.removeWidget(1)
        assertFalse(l.campMenu)
        assertEquals(listOf(2), l.board.ids)
        assertEquals(listOf("delete:1"), widgets.calls)
        assertEquals(listOf(PlacedLabel(2, "b")), l.placedWidgets())
    }

    @Test
    fun `allowing dots closes the camp menu and opens the system page`() {
        val l = launcher()
        l.openCampMenu()
        l.allowDots()
        assertFalse(l.campMenu)
        assertEquals(listOf("notificationAccess"), actions.calls)
    }

    @Test
    fun `back from the petate and dismissing sheets`() {
        val l = launcher()
        l.openPetate(false)
        assertTrue(l.back())
        assertEquals(Screen.CAMPAMENTO, l.screen)
        assertFalse(l.back())
        l.openMenu("com.termux"); l.dismissMenu(); assertNull(l.menu)
        l.openCampMenu(); l.dismissCampMenu(); assertFalse(l.campMenu)
        widgets.offered = listOf(clock); l.showPicker(); l.dismissPicker(); assertNull(l.picker)
    }

    @Test
    fun `home pressed closes any open sheet too`() {
        val l = launcher()
        l.openMenu("com.termux")
        l.onHomePressed()
        assertNull(l.menu)
    }

    @Test
    fun `the last pitch remembers what you opened, newest first, five at most, without repeats`() {
        val l = launcher()
        l.openApp("com.termux")
        l.openFromPetate("app.organicmaps")
        l.openApp("com.termux")
        assertEquals(listOf("com.termux", "app.organicmaps"), l.recent)
        listOf("a", "b", "c", "d").forEach { l.openApp(it) }
        assertEquals(listOf("d", "c", "b", "a", "com.termux"), l.recent)
    }

    @Test
    fun `the last pitch survives a restart and forgets uninstalled apps`() {
        launcher().apply { openApp("org.thoughtcrime.securesms"); openApp("com.termux") }
        source.apps = listOf(termux, maps, settings)
        assertEquals(listOf("com.termux"), launcher().recent)
    }

    @Test
    fun `hidden apps stay out of the last pitch`() {
        val l = launcher()
        l.openApp("com.termux")
        l.openApp("app.organicmaps")
        l.openMenu("app.organicmaps")
        l.pick(MenuEntry.Hide(false))
        assertEquals(listOf("com.termux"), l.visibleRecent())
    }
}
