package dev.vivac.launcher.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.vivac.launcher.apps.AppSource
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.campamento.Dock
import dev.vivac.launcher.campamento.DockSlot
import dev.vivac.launcher.campamento.Home
import dev.vivac.launcher.campamento.HomeChange
import dev.vivac.launcher.campamento.WidgetBoard
import dev.vivac.launcher.petate.AppMenu
import dev.vivac.launcher.petate.MenuEntry
import dev.vivac.launcher.widgets.WidgetOption

enum class Screen { CAMPAMENTO, PETATE }

/** The two answers Android sends back while placing a widget. */
enum class WidgetStep { BIND, CONFIGURE }

data class OpenMenu(val app: InstalledApp, val entries: List<MenuEntry>, val canReadShortcuts: Boolean)

data class PlacedLabel(val id: Int, val label: String)

/**
 * vivac's state and decisions, free of Android: what is on screen, the layout you chose,
 * and what happens when you tap, long-press or come back from a system dialog.
 */
class Launcher(
    private val source: AppSource,
    private val store: Store,
    private val actions: Actions,
    private val widgets: WidgetHost,
    /** The widget id waiting for the bind dialog or its setup screen, restored after process death. */
    pendingWidget: Int = -1,
) {
    var apps by mutableStateOf(emptyList<InstalledApp>()); private set
    var home by mutableStateOf(Home.decode(store.get(KEY_DOCK), store.get(KEY_PINNED), store.get(KEY_HIDDEN))); private set
    var board by mutableStateOf(WidgetBoard.decode(store.get(KEY_WIDGETS)).let { b -> WidgetBoard(b.ids.filter(widgets::exists)) }); private set
    var screen by mutableStateOf(Screen.CAMPAMENTO); private set
    var focusSearch by mutableStateOf(false); private set
    var menu by mutableStateOf<OpenMenu?>(null); private set
    var campMenu by mutableStateOf(false); private set
    var picker by mutableStateOf<List<WidgetOption>?>(null); private set
    var pendingWidget = pendingWidget; private set

    fun refresh() {
        apps = source.installed()
        // An empty list means Android is not ready (e.g. right after boot), not that every app is gone:
        // never let that wipe the dock and pins.
        if (apps.isNotEmpty()) {
            val kept = home.keepOnly(apps.map { it.packageName }.toSet())
            if (kept != home) apply(HomeChange(kept))
        }
    }

    /** Hidden apps never reach the Campamento (dock, pins); only the Petate's "Ocultas" shows them. */
    fun visibleApps(): List<InstalledApp> {
        val hidden = home.hidden.toSet()
        return apps.filter { it.packageName !in hidden }
    }

    /** The dock as it is on screen: your choice, or the default favourites until you edit it. */
    fun shownDock(): List<String> =
        Dock.pick(visibleApps().map { it.packageName }.toSet(), home.dock).filterIsInstance<DockSlot.App>().map { it.packageName }

    fun openPetate(search: Boolean) {
        focusSearch = search
        screen = Screen.PETATE
    }

    fun openApp(packageName: String) = actions.open(packageName)

    fun openFromPetate(packageName: String) {
        actions.open(packageName)
        screen = Screen.CAMPAMENTO
    }

    /** Back: from the Petate to the camp. False when there was nowhere to go back to. */
    fun back(): Boolean {
        if (screen == Screen.CAMPAMENTO) return false
        screen = Screen.CAMPAMENTO
        return true
    }

    /** Pressing Home while vivac is in front: close whatever is open and return to the camp. */
    fun onHomePressed() {
        menu = null
        campMenu = false
        picker = null
        screen = Screen.CAMPAMENTO
    }

    fun openMenu(packageName: String) {
        val app = apps.find { it.packageName == packageName } ?: return
        val entries = AppMenu.build(
            actions.shortcuts(packageName),
            app.isSystem,
            inDock = packageName in shownDock(),
            pinned = packageName in home.pinned,
            hidden = packageName in home.hidden,
        )
        menu = OpenMenu(app, entries, actions.canReadShortcuts())
    }

    fun dismissMenu() { menu = null }

    fun pick(entry: MenuEntry) {
        val app = menu?.app ?: return
        menu = null
        val pkg = app.packageName
        when (entry) {
            is MenuEntry.Shortcut -> actions.openShortcut(pkg, entry.shortcut.id)
            is MenuEntry.Dock -> apply(home.copy(dock = shownDock()).toggleDock(pkg))
            is MenuEntry.Pin -> apply(home.togglePin(pkg))
            is MenuEntry.Hide -> apply(HomeChange(home.toggleHidden(pkg)))
            MenuEntry.Info -> actions.info(pkg)
            MenuEntry.Uninstall -> actions.uninstall(pkg)
        }
    }

    fun openCampMenu() { campMenu = true }
    fun dismissCampMenu() { campMenu = false }

    fun placedWidgets(): List<PlacedLabel> = board.ids.map { PlacedLabel(it, widgets.label(it)) }

    fun showPicker() {
        campMenu = false
        picker = widgets.options()
    }

    fun dismissPicker() { picker = null }

    fun allowDots() {
        campMenu = false
        actions.notificationAccess()
    }

    /** Placing a widget: allocate an id, get the bind permission if needed, then its configuration if it has one. */
    fun addWidget(option: WidgetOption) {
        picker = null
        val id = widgets.allocate()
        pendingWidget = id
        if (widgets.bindIfAllowed(id, option)) afterBind(id) else widgets.requestBind(id, option)
    }

    fun onWidgetResult(step: WidgetStep, ok: Boolean) {
        val id = pendingWidget
        if (id == -1) return
        when {
            !ok -> { widgets.delete(id); pendingWidget = -1 }
            step == WidgetStep.BIND -> afterBind(id)
            else -> placeWidget(id)
        }
    }

    fun removeWidget(id: Int) {
        campMenu = false
        widgets.delete(id)
        saveBoard(board.remove(id))
    }

    private fun afterBind(id: Int) {
        if (widgets.needsConfiguring(id)) widgets.requestConfigure(id) else placeWidget(id)
    }

    private fun placeWidget(id: Int) {
        pendingWidget = -1
        saveBoard(board.add(id))
    }

    private fun saveBoard(next: WidgetBoard) {
        board = next
        store.put(mapOf(KEY_WIDGETS to next.encode()))
    }

    private fun apply(change: HomeChange) {
        val next = change.home ?: return actions.say(change.refusal.orEmpty())
        home = next
        store.put(mapOf(KEY_DOCK to next.encodeDock(), KEY_PINNED to next.encodePinned(), KEY_HIDDEN to next.encodeHidden()))
    }

    companion object {
        const val KEY_DOCK = "dock"
        const val KEY_PINNED = "pinned"
        const val KEY_HIDDEN = "hidden"
        const val KEY_WIDGETS = "widgets"
    }
}
