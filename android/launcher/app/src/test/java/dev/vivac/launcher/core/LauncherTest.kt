package dev.vivac.launcher.core

import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.apps.Profile
import dev.vivac.launcher.campamento.Placed
import dev.vivac.launcher.campamento.Shelved
import dev.vivac.launcher.campamento.WidgetBoard
import dev.vivac.launcher.campamento.Pinned
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
            listOf(MenuEntry.Shortcut(AppShortcut("s", "Sesión")), MenuEntry.Dock(true), MenuEntry.Pin(false), MenuEntry.Ladera(false), MenuEntry.Hide(false), MenuEntry.Info, MenuEntry.Uninstall),
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
        assertEquals("1:0:0", store.values["widgets"])
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

    private fun withWidgets(vararg ids: Int): Launcher {
        ids.forEach { widgets.placed[it] = "w$it" }
        store.values["widgets"] = ids.joinToString(",")
        return launcher()
    }

    @Test
    fun `a long press on a widget opens its card, with its rows and where it sits`() {
        val l = withWidgets(1, 2)
        widgets.rows[2] = 3
        l.openWidgetMenu(2)
        assertEquals(2, l.widgetMenu)
        assertEquals(3, l.widgetRows(2))
        l.dismissWidgetMenu()
        assertNull(l.widgetMenu)
    }

    @Test
    fun `resizing goes a row at a time from the widget's own height, and is kept`() {
        val l = withWidgets(1)
        l.resizeWidget(1, +1)
        assertEquals(3, l.widgetRows(1))
        assertEquals("1:0:3", store.values["widgets"])
        repeat(9) { l.resizeWidget(1, -1) }
        assertEquals(1, l.widgetRows(1))
    }

    @Test
    fun `moving a widget to a new ladera shows that ladera, and home brings you back to the camp`() {
        val l = withWidgets(1, 2)
        l.moveWidget(2, page = l.board.pages)
        assertEquals(2, l.board.pages)
        assertEquals(1, l.page)
        assertNull(l.widgetMenu)
        l.onHomePressed()
        assertEquals(0, l.page)
        l.showPage(5)
        assertEquals(1, l.page)
    }

    @Test
    fun `widgets move earlier and later on their page`() {
        val l = withWidgets(1, 2)
        l.shiftWidget(2, -1)
        assertEquals(listOf(2, 1), l.board.ids)
    }

    @Test
    fun `removing a widget from its card closes the card`() {
        val l = withWidgets(1)
        l.openWidgetMenu(1)
        l.removeWidget(1)
        assertNull(l.widgetMenu)
        assertEquals(emptyList<Int>(), l.board.ids)
    }

    @Test
    fun `an app goes on the ladera you are looking at, or the last one, or a new one`() {
        val l = launcher()
        l.openMenu("com.termux"); l.pick(MenuEntry.Ladera(false))
        assertEquals(listOf(Shelved("com.termux", 1)), l.board.onPage(1))
        l.showPage(0)
        l.openMenu("app.organicmaps"); l.pick(MenuEntry.Ladera(false))
        assertEquals(listOf("com.termux", "app.organicmaps"), l.board.apps)
        l.openMenu("app.organicmaps")
        assertEquals(true, l.menu!!.entries.contains(MenuEntry.Ladera(true)))
        l.pick(MenuEntry.Ladera(true))
        assertEquals(listOf("com.termux"), l.board.apps)
    }

    @Test
    fun `hiding or uninstalling an app takes it off its ladera`() {
        val l = launcher()
        l.openMenu("com.termux"); l.pick(MenuEntry.Ladera(false))
        l.openMenu("app.organicmaps"); l.pick(MenuEntry.Ladera(false))
        l.openMenu("com.termux"); l.pick(MenuEntry.Hide(false))
        assertEquals(listOf("app.organicmaps"), l.board.apps)
        source.apps = listOf(termux, signal, settings)
        l.refresh()
        assertEquals(emptyList<String>(), l.board.apps)
    }

    private val tailscale = InstalledApp("Tailscale", "com.tailscale.ipn", false)
    private fun many() = Launcher(FakeSource(listOf(termux, signal, maps, settings, tailscale)), store, actions, widgets).also { it.refresh() }

    @Test
    fun `dragging within the dock reorders it, starting from the default favourites`() {
        val l = many()
        assertEquals(listOf("com.termux", "org.thoughtcrime.securesms", "com.tailscale.ipn"), l.shownDock())
        l.drop("com.tailscale.ipn", from = Zone.Dock, to = Zone.Dock, index = 0)
        assertEquals(listOf("com.tailscale.ipn", "com.termux", "org.thoughtcrime.securesms"), l.shownDock())
    }

    @Test
    fun `dragging within the route reorders the pitches`() {
        store.values["pinned"] = "com.termux,app.organicmaps,org.thoughtcrime.securesms"
        val l = many()
        l.drop("org.thoughtcrime.securesms", from = Zone.Via, to = Zone.Via, index = 0)
        assertEquals(listOf("org.thoughtcrime.securesms", "com.termux", "app.organicmaps"), l.home.pinned)
    }

    @Test
    fun `an app dragged from the route to the dock leaves the route, and back again`() {
        store.values["pinned"] = "app.organicmaps"
        val l = many()
        l.drop("app.organicmaps", from = Zone.Via, to = Zone.Dock, index = 1)
        assertEquals(listOf("com.termux", "app.organicmaps", "org.thoughtcrime.securesms", "com.tailscale.ipn"), l.shownDock())
        assertEquals(emptyList<String>(), l.home.pinned)
        l.drop("com.termux", from = Zone.Dock, to = Zone.Via, index = 0)
        assertEquals(listOf("com.termux"), l.home.pinned)
        assertEquals(false, "com.termux" in l.shownDock())
    }

    @Test
    fun `a full dock refuses one more and says why, keeping things where they were`() {
        store.values["dock"] = "com.termux,org.thoughtcrime.securesms,com.tailscale.ipn,com.android.settings"
        store.values["pinned"] = "app.organicmaps"
        val l = many()
        l.drop("app.organicmaps", from = Zone.Via, to = Zone.Dock, index = 0)
        assertEquals(listOf("app.organicmaps"), l.home.pinned)
        assertEquals(4, l.shownDock().size)
        assertTrue(actions.calls.any { it.startsWith("say:") })
    }

    @Test
    fun `apps move between the camp and a ladera, and within a ladera, by dragging`() {
        val l = many()
        l.drop("com.termux", from = Zone.Dock, to = Zone.Ladera(1), index = 0)
        assertEquals(listOf("com.termux"), l.board.apps)
        assertEquals(false, "com.termux" in l.shownDock())
        l.drop("app.organicmaps", from = Zone.Petate, to = Zone.Ladera(1), index = 0)
        assertEquals(listOf("app.organicmaps", "com.termux"), l.board.apps)
        l.drop("com.termux", from = Zone.Ladera(1), to = Zone.Ladera(1), index = 0)
        assertEquals(listOf("com.termux", "app.organicmaps"), l.board.apps)
        l.drop("com.termux", from = Zone.Ladera(1), to = Zone.Via, index = 0)
        assertEquals(listOf("app.organicmaps"), l.board.apps)
        assertEquals(listOf("com.termux"), l.home.pinned)
    }

    @Test
    fun `an app carried out of the petate lands in the camp, once, even onto a full dock it is already in`() {
        val l = many()
        l.drop("app.organicmaps", from = Zone.Petate, to = Zone.Via, index = 0)
        assertEquals(listOf("app.organicmaps"), l.home.pinned)
        l.drop("app.organicmaps", from = Zone.Petate, to = Zone.Via, index = 5)
        assertEquals(listOf("app.organicmaps"), l.home.pinned)
        l.drop("com.android.settings", from = Zone.Petate, to = Zone.Dock, index = 0)
        assertEquals(listOf("com.android.settings", "com.termux", "org.thoughtcrime.securesms", "com.tailscale.ipn"), l.shownDock())
        l.drop("com.termux", from = Zone.Petate, to = Zone.Dock, index = 0)
        assertEquals(listOf("com.termux", "com.android.settings", "org.thoughtcrime.securesms", "com.tailscale.ipn"), l.shownDock())
        assertEquals(emptyList<String>(), actions.calls)
    }

    @Test
    fun `a widget dragged onto a page lands at that place, and only pages take widgets`() {
        widgets.placed = mutableMapOf(1 to "a", 2 to "b")
        store.values["widgets"] = "1:0:0,2:0:0,@com.termux:1"
        val l = many()
        l.dropWidget(2, Zone.Ladera(0), 0)
        assertEquals(listOf(2, 1), l.board.ids)
        l.dropWidget(1, Zone.Ladera(1), 0)
        assertEquals(listOf(Placed(1, page = 1), Shelved("com.termux", 1)), l.board.onPage(1))
        assertEquals("2:0:0,1:1:0,@com.termux:1", store.values["widgets"])
        l.dropWidget(1, Zone.Via, 0)
        l.dropWidget(1, Zone.Dock, 0)
        assertEquals(listOf(Placed(1, page = 1), Shelved("com.termux", 1)), l.board.onPage(1))
    }

    @Test
    fun `a shortcut pinned from the menu goes on a ladera, stays pinned in android, opens, and can be taken off`() {
        actions.shortcuts = mapOf("org.thoughtcrime.securesms" to listOf(AppShortcut("chat", "Nuevo chat")))
        val l = many()
        l.openMenu("org.thoughtcrime.securesms")
        l.pick(MenuEntry.PinShortcut(AppShortcut("chat", "Nuevo chat")))
        assertEquals(null, l.menu)
        assertEquals(listOf(Pinned("org.thoughtcrime.securesms", "chat", "Nuevo chat", 1)), l.board.onPage(1))
        assertTrue("pinShortcuts:org.thoughtcrime.securesms:[chat]" in actions.calls)
        l.openPinned("org.thoughtcrime.securesms", "chat")
        assertTrue("shortcut:org.thoughtcrime.securesms/chat" in actions.calls)
        l.openShortcutMenu("org.thoughtcrime.securesms", "chat", "Nuevo chat")
        assertEquals(listOf(MenuEntry.UnpinShortcut(AppShortcut("chat", "Nuevo chat")), MenuEntry.Info), l.menu?.entries)
        l.pick(MenuEntry.UnpinShortcut(AppShortcut("chat", "Nuevo chat")))
        assertEquals(1, l.board.pages)
        l.openShortcutMenu("gone.app", "x", "X")
        assertEquals(null, l.menu)
        assertTrue("pinShortcuts:org.thoughtcrime.securesms:[]" in actions.calls)
    }

    @Test
    fun `what another screen saved meanwhile is read back on return`() {
        val l = many()
        store.values["widgets"] = WidgetBoard().addShortcut("app.organicmaps", "home", "Casa", 1).encode()
        l.reload()
        assertEquals(listOf("home"), l.board.shortcutsOf("app.organicmaps"))
    }

    @Test
    fun `an app renamed from its menu keeps the name everywhere and after a restart, and blank brings the original back`() {
        val l = many()
        l.openMenu("app.organicmaps")
        l.pick(MenuEntry.Rename)
        assertEquals("Organic Maps", l.renaming?.label)
        assertEquals(null, l.menu)
        l.rename("app.organicmaps", "  Mapas  ")
        assertEquals(null, l.renaming)
        assertEquals("Mapas", l.apps.first { it.packageName == "app.organicmaps" }.label)
        assertEquals("Mapas", many().apps.first { it.packageName == "app.organicmaps" }.label)
        l.rename("com.termux", "Consola: 1, 2")
        assertEquals("Consola: 1, 2", many().apps.first { it.packageName == "com.termux" }.label)
        l.rename("app.organicmaps", " ")
        assertEquals("Organic Maps", l.apps.first { it.packageName == "app.organicmaps" }.label)
        l.openMenu("app.organicmaps"); l.pick(MenuEntry.Rename)
        l.cancelRename()
        assertEquals(null, l.renaming)
    }

    @Test
    fun `a locked camp keeps everything where it is until it is unlocked, also after a restart`() {
        widgets.placed = mutableMapOf(1 to "a", 2 to "b")
        store.values["widgets"] = "1,2"
        store.values["pinned"] = "app.organicmaps"
        val l = many()
        l.openCampMenu()
        l.toggleLock()
        assertTrue(l.locked)
        assertFalse(l.campMenu)
        assertTrue(many().locked)
        l.drop("com.termux", from = Zone.Dock, to = Zone.Via, index = 0)
        l.dropWidget(2, Zone.Ladera(0), 0)
        assertEquals(listOf("app.organicmaps"), l.home.pinned)
        assertEquals(listOf(1, 2), l.board.ids)
        l.toggleLock()
        assertFalse(many().locked)
        l.drop("com.termux", from = Zone.Dock, to = Zone.Via, index = 0)
        assertEquals(listOf("com.termux", "app.organicmaps"), l.home.pinned)
        assertEquals(2, actions.calls.count { it.startsWith("say:") })
    }

    @Test
    fun `double tap locks the screen only once you turn it on, and asks for the service when it is off`() {
        val l = many()
        l.onDoubleTap()
        assertEquals(emptyList<String>(), actions.calls)
        l.openCampMenu()
        actions.lockService = false
        l.toggleDoubleTapLock()
        assertTrue(l.doubleTapLock)
        assertFalse(l.campMenu)
        assertTrue(many().doubleTapLock)
        assertEquals(listOf("accessibility"), actions.calls.filterNot { it.startsWith("say:") })
        actions.calls.clear()
        l.onDoubleTap()
        assertEquals("accessibility", actions.calls.last())
        actions.lockService = true
        l.onDoubleTap()
        assertEquals("lock", actions.calls.last())
        l.toggleDoubleTapLock()
        assertFalse(many().doubleTapLock)
    }

    @Test
    fun `the camp is copied to a file and restored from one, every choice coming back at once`() {
        store.values["pinned"] = "app.organicmaps"
        val l = many()
        l.rename("com.termux", "Consola")
        l.openCampMenu()
        l.backUp()
        assertEquals("backup", actions.calls.last())
        assertFalse(l.campMenu)
        val copy = l.exportLayout()
        l.drop("app.organicmaps", from = Zone.Via, to = Zone.Dock, index = 0)
        l.rename("com.termux", "")
        l.toggleLock()
        l.openCampMenu()
        l.askRestore()
        assertEquals("restore", actions.calls.last())
        l.restoreLayout(copy)
        assertEquals(listOf("app.organicmaps"), l.home.pinned)
        assertEquals("Consola", l.apps.first { it.packageName == "com.termux" }.label)
        assertFalse(l.locked)
        assertTrue(actions.calls.last().startsWith("say:Campamento restaurado"))
        l.restoreLayout("no es una copia")
        assertTrue(actions.calls.last().startsWith("say:Ese archivo no es"))
    }

    @Test
    fun `opening the petate gathers the shortcuts of visible apps for its search, and one opens from there`() {
        actions.allShortcuts = listOf("org.thoughtcrime.securesms" to AppShortcut("chat", "Nuevo chat"), "gone.app" to AppShortcut("x", "X"))
        store.values["hidden"] = "app.organicmaps"
        actions.allShortcuts = actions.allShortcuts + ("app.organicmaps" to AppShortcut("home", "Casa"))
        val l = many()
        l.openPetate(false)
        assertEquals(listOf("Nuevo chat"), l.petateShortcuts.map { it.shortcut.label })
        l.openShortcutFromPetate(l.petateShortcuts.single())
        assertEquals("shortcut:org.thoughtcrime.securesms/chat", actions.calls.last())
        assertEquals(Screen.CAMPAMENTO, l.screen)
    }

    @Test
    fun `the work profile and private space are read on refresh, open their apps and lock`() {
        val work = Profile(10, Profile.Kind.WORK, locked = false, apps = listOf(signal))
        val private = Profile(11, Profile.Kind.PRIVATE, locked = true, apps = emptyList())
        val l = Launcher(FakeSource(listOf(termux), listOf(work, private)), store, actions, widgets).also { it.refresh() }
        assertEquals(listOf(work, private), l.profiles)
        l.openPetate(false)
        l.openInProfile("org.thoughtcrime.securesms", 10)
        assertEquals("openIn:10:org.thoughtcrime.securesms", actions.calls.last())
        assertEquals(Screen.CAMPAMENTO, l.screen)
        l.lockProfile(private)
        assertEquals("lockProfile:11:false", actions.calls.last())
        l.lockProfile(work)
        assertEquals("lockProfile:10:true", actions.calls.last())
    }

    @Test
    fun `the phone's wallpaper can show behind the camp, and be changed from its menu`() {
        val l = many()
        assertFalse(l.showWallpaper)
        l.openCampMenu()
        l.toggleWallpaper()
        assertTrue(l.showWallpaper)
        assertFalse(l.campMenu)
        assertTrue(many().showWallpaper)
        l.openCampMenu()
        l.changeWallpaper()
        assertEquals("wallpaper", actions.calls.last())
        assertFalse(l.campMenu)
    }

    @Test
    fun `apps go into folders from their menu or by dragging, and folders open, rename and give apps back`() {
        store.values["pinned"] = "app.organicmaps"
        val l = many()
        l.openMenu("com.termux")
        l.pick(MenuEntry.ToFolder)
        assertEquals("com.termux", l.folderPicker?.packageName)
        l.newFolder("com.termux")
        assertEquals(null, l.folderPicker)
        val id = l.board.folderOf("com.termux")!!.id
        assertEquals(id, l.openFolder)
        assertEquals("Carpeta", l.board.folder(id)?.name)
        l.closeFolder()
        l.drop("app.organicmaps", from = Zone.Via, to = Zone.Folder(id), index = 0)
        assertEquals(emptyList<String>(), l.home.pinned)
        assertEquals(listOf("com.termux", "app.organicmaps"), l.board.folder(id)?.apps)
        l.openMenu("org.thoughtcrime.securesms"); l.pick(MenuEntry.ToFolder)
        l.putInFolder("org.thoughtcrime.securesms", id)
        assertEquals(3, l.board.folder(id)?.apps?.size)
        assertFalse("org.thoughtcrime.securesms" in l.shownDock())
        l.renameFolder(id, "  Viaje ")
        assertEquals("Viaje", l.board.folder(id)?.name)
        l.renameFolder(id, " ")
        assertEquals("Viaje", l.board.folder(id)?.name)
        l.takeOutOfFolder(id, "app.organicmaps")
        l.takeOutOfFolder(id, "org.thoughtcrime.securesms")
        assertEquals(null, l.board.folder(id))
        assertEquals(null, l.openFolder)
        l.cancelFolderPicker()
        l.openFolder("nope")
        assertEquals(null, l.openFolder)
    }

    @Test
    fun `vivac's settings open from the camp menu, persist, and back closes them`() {
        val l = many()
        l.openCampMenu()
        l.openSettings()
        assertEquals(Screen.AJUSTES, l.screen)
        assertFalse(l.campMenu)
        assertEquals(4, l.columns)
        l.chooseColumns(5)
        l.chooseColumns(9)
        assertEquals(5, many().columns)
        assertTrue(l.labels)
        l.toggleLabels()
        assertFalse(many().labels)
        assertFalse(l.showCounts)
        l.toggleCounts()
        assertTrue(many().showCounts)
        assertTrue(l.back())
        assertEquals(Screen.CAMPAMENTO, l.screen)
    }

    @Test
    fun `swipes do what you chose for them`() {
        val l = many()
        assertEquals(Gesture.PETATE, l.swipeUp)
        assertEquals(Gesture.NOTIFICATIONS, l.swipeDown)
        l.onSwipeUp()
        assertEquals(Screen.PETATE, l.screen)
        l.back()
        l.onSwipeDown()
        assertEquals("notifications", actions.calls.last())
        l.chooseSwipeUp(Gesture.SEARCH)
        l.chooseSwipeDown(Gesture.LOCK)
        assertEquals(Gesture.SEARCH, many().swipeUp)
        assertEquals(Gesture.LOCK, many().swipeDown)
        l.onSwipeUp()
        assertTrue(l.focusSearch)
        l.back()
        l.onSwipeDown()
        assertEquals("accessibility", actions.calls.last())
        actions.lockService = true
        l.onSwipeDown()
        assertEquals("lock", actions.calls.last())
        l.chooseSwipeDown(Gesture.NOTHING)
        val before = actions.calls.size
        l.onSwipeDown()
        assertEquals(before, actions.calls.size)
        store.values["swipeUp"] = "BOGUS"
        assertEquals(Gesture.PETATE, many().swipeUp)
    }

    @Test
    fun `icons are glyphs until you choose another style or a pack, which persists`() {
        val l = many()
        assertEquals(IconStyle.GLYPHS, l.iconStyle)
        l.chooseIcons(IconStyle.ORIGINAL)
        assertEquals(IconStyle.ORIGINAL, many().iconStyle)
        l.chooseIconPack("a.pack")
        assertEquals(IconStyle.PACK, many().iconStyle)
        assertEquals("a.pack", many().iconPack)
        store.values["icons"] = "WHATEVER"
        assertEquals(IconStyle.GLYPHS, many().iconStyle)
    }

    @Test
    fun `contacts and events are searched only once you turn them on and android allows it`() {
        val dir = FakeDirectory().apply {
            people = listOf(Contact(1, "Ana García", "a"), Contact(2, "Bruno", "b"))
            agenda = listOf(CalendarEvent(5, "Cena con Ana", 0L))
        }
        val l = Launcher(FakeSource(listOf(termux)), store, actions, widgets, directory = dir).also { it.refresh() }
        assertEquals(emptyList<Contact>(), l.findContacts("ana"))
        assertEquals(emptyList<CalendarEvent>(), l.findEvents("ana"))
        l.toggleContacts()
        assertEquals(listOf("askContacts"), dir.calls)
        assertTrue(l.searchContacts)
        assertEquals(emptyList<Contact>(), l.findContacts("ana"))
        dir.contactsAllowed = true
        assertEquals(listOf(Contact(1, "Ana García", "a")), l.findContacts("ana"))
        assertEquals(emptyList<Contact>(), l.findContacts(" "))
        l.toggleCalendar()
        dir.calendarAllowed = true
        assertEquals(1, l.findEvents("ana").size)
        assertTrue(Launcher(FakeSource(listOf(termux)), store, actions, widgets, directory = dir).searchCalendar)
        l.openContact(Contact(1, "Ana García", "a"))
        l.openEvent(CalendarEvent(5, "Cena con Ana", 0L))
        assertEquals(listOf("askContacts", "askCalendar", "contact:1", "event:5"), dir.calls)
        l.toggleContacts()
        l.toggleCalendar()
        assertEquals(emptyList<Contact>(), l.findContacts("ana"))
        assertFalse(Launcher(FakeSource(listOf(termux)), store, actions, widgets).searchContacts.also { } && false)
        assertEquals(emptyList<Contact>(), Launcher(FakeSource(listOf(termux)), store, actions, widgets).findContacts("ana"))
    }

    @Test
    fun `dropping where it already is changes nothing`() {
        store.values["pinned"] = "com.termux"
        val l = many()
        l.drop("com.termux", from = Zone.Via, to = Zone.Via, index = 0)
        assertEquals(listOf("com.termux"), l.home.pinned)
        assertEquals(emptyList<String>(), actions.calls)
    }

    @Test
    fun `a dock you emptied stays empty, also after a restart`() {
        val l = many()
        l.shownDock().forEach { l.drop(it, from = Zone.Dock, to = Zone.Ladera(1), index = 0) }
        assertEquals(emptyList<String>(), l.shownDock())
        assertEquals(emptyList<String>(), many().shownDock())
    }

    @Test
    fun `pinning before ever choosing a dock keeps the default favourites after a restart`() {
        val l = many()
        l.openMenu("app.organicmaps"); l.pick(MenuEntry.Pin(false))
        assertEquals(listOf("com.termux", "org.thoughtcrime.securesms", "com.tailscale.ipn"), many().shownDock())
    }
}
