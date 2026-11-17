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
import dev.vivac.launcher.campamento.Placed
import dev.vivac.launcher.campamento.Shelved
import dev.vivac.launcher.campamento.WidgetBoard
import dev.vivac.launcher.petate.AppMenu
import dev.vivac.launcher.petate.AppShortcut
import dev.vivac.launcher.petate.MenuEntry
import dev.vivac.launcher.widgets.WidgetOption

enum class Screen { CAMPAMENTO, PETATE }

/** Where an app sits on the home screen, as a drag sees it: picked up from one zone, dropped in another. */
sealed interface Zone {
    data object Dock : Zone
    data object Via : Zone
    data class Ladera(val page: Int) : Zone
    /** Not on the home screen yet (dragged in from the Petate). */
    data object Petate : Zone
}

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
    var board by mutableStateOf(loadBoard()); private set
    /** The home page in view: 0 is the Campamento, 1 onwards the laderas. */
    var page by mutableStateOf(0); private set
    /** The widget whose card is open (after a long press on it). */
    var widgetMenu by mutableStateOf<Int?>(null); private set
    var screen by mutableStateOf(Screen.CAMPAMENTO); private set
    var focusSearch by mutableStateOf(false); private set
    var menu by mutableStateOf<OpenMenu?>(null); private set
    var campMenu by mutableStateOf(false); private set
    var picker by mutableStateOf<List<WidgetOption>?>(null); private set
    var pendingWidget = pendingWidget; private set
    /** "Último largo": what you opened through vivac, newest first. vivac's own history, no usage permission. */
    var recent by mutableStateOf(store.get(KEY_RECENT).orEmpty().split(",").filter { it.isNotBlank() }); private set

    /** Names you gave apps, by package. */
    private var names = decodeNames(store.get(KEY_NAMES))
    private var installed = emptyList<InstalledApp>()
    /** The app whose name you are changing (from its menu). */
    var renaming by mutableStateOf<InstalledApp?>(null); private set
    /** Locked: nothing on the home screen can be dragged until you unlock it from the camp menu. */
    var locked by mutableStateOf(store.get(KEY_LOCKED) == "1"); private set

    fun toggleLock() {
        campMenu = false
        locked = !locked
        store.put(mapOf(KEY_LOCKED to if (locked) "1" else "0"))
        actions.say(if (locked) "Campamento bloqueado: nada se mueve hasta que lo desbloquees." else "Campamento desbloqueado.")
    }

    fun refresh() {
        installed = source.installed()
        apps = named()
        // An empty list means Android is not ready (e.g. right after boot), not that every app is gone:
        // never let that wipe the dock and pins.
        if (apps.isNotEmpty()) {
            val installed = apps.map { it.packageName }.toSet()
            val kept = home.keepOnly(installed)
            if (kept != home) apply(HomeChange(kept))
            if (recent.any { it !in installed }) saveRecent(recent.filter { it in installed })
            board.keepApps(installed).takeIf { it != board }?.let(::saveBoard)
        }
    }

    /** Hidden apps never reach the Campamento (dock, pins); only the Petate's "Ocultas" shows them. */
    fun visibleApps(): List<InstalledApp> {
        val hidden = home.hidden.toSet()
        return apps.filter { it.packageName !in hidden }
    }

    /** The dock as it is on screen: your choice, or the default favourites until you edit it. */
    fun shownDock(): List<String> =
        Dock.pick(visibleApps().map { it.packageName }.toSet(), home.dock, home.dockChosen).filterIsInstance<DockSlot.App>().map { it.packageName }

    fun openPetate(search: Boolean) {
        focusSearch = search
        screen = Screen.PETATE
    }

    fun openApp(packageName: String) {
        actions.open(packageName)
        saveRecent((listOf(packageName) + (recent - packageName)).take(RECENT_MAX))
    }

    fun openFromPetate(packageName: String) {
        openApp(packageName)
        screen = Screen.CAMPAMENTO
    }

    /** The last pitch as the Petate shows it: hidden apps stay out. */
    fun visibleRecent(): List<String> = recent.filter { it !in home.hidden }

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
        widgetMenu = null
        page = 0
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
            onLadera = packageName in board.apps,
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
            is MenuEntry.UnpinShortcut -> unpinShortcut(pkg, entry.shortcut.id)
            is MenuEntry.PinShortcut -> {
                saveBoard(board.addShortcut(pkg, entry.shortcut.id, entry.shortcut.label, ladera()))
                actions.pinShortcuts(pkg, board.shortcutsOf(pkg))
            }
            is MenuEntry.Dock -> apply(home.copy(dock = shownDock()).toggleDock(pkg))
            is MenuEntry.Pin -> apply(home.togglePin(pkg))
            is MenuEntry.Ladera -> saveBoard(if (entry.onLadera) board.removeApp(pkg) else board.addApp(pkg, ladera()))
            is MenuEntry.Hide -> {
                apply(HomeChange(home.toggleHidden(pkg)))
                if (pkg in home.hidden) saveBoard(board.removeApp(pkg))
            }
            MenuEntry.Rename -> renaming = app
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

    /**
     * A dragged app let go over [to] at [index]: it ends up at that place, leaving where it was. A full dock or
     * route refuses it and says why; dropping it where it already was changes nothing.
     */
    fun drop(packageName: String, from: Zone, to: Zone, index: Int) {
        if (locked) return
        if (from == to && position(packageName, from) == index) return
        val dock = shownDock().toMutableList()
        val pinned = home.pinned.toMutableList()
        var next = board
        when (from) {
            Zone.Dock -> dock.remove(packageName)
            Zone.Via -> pinned.remove(packageName)
            is Zone.Ladera -> if (to !is Zone.Ladera) next = next.removeApp(packageName)
            // Out of the petate: an app already where it lands moves rather than appearing twice.
            Zone.Petate -> if (to == Zone.Dock) dock.remove(packageName) else if (to == Zone.Via) pinned.remove(packageName)
        }
        when (to) {
            Zone.Dock -> {
                if (dock.size >= Home.DOCK_MAX) return actions.say("El dock ya tiene ${Home.DOCK_MAX} apps: quita una primero.")
                dock.add(index.coerceIn(0, dock.size), packageName)
            }
            Zone.Via -> {
                if (pinned.size >= Home.PINNED_MAX) return actions.say("La vía ya tiene ${Home.PINNED_MAX} largos: quita uno primero.")
                pinned.add(index.coerceIn(0, pinned.size), packageName)
            }
            is Zone.Ladera -> next = next.insertApp(packageName, to.page, index)
            Zone.Petate -> Unit
        }
        val dockTouched = from == Zone.Dock || to == Zone.Dock
        apply(HomeChange(home.copy(dock = if (dockTouched) dock else home.dock, pinned = pinned, dockChosen = home.dockChosen || dockTouched)))
        if (next != board) saveBoard(next)
    }

    private fun position(packageName: String, zone: Zone): Int = when (zone) {
        Zone.Dock -> shownDock().indexOf(packageName)
        Zone.Via -> home.pinned.indexOf(packageName)
        is Zone.Ladera -> board.onPage(zone.page).indexOfFirst { it is Shelved && it.packageName == packageName }
        Zone.Petate -> -1
    }

    /** The ladera an app goes to: the one in view, else the last one, else a new one. */
    private fun ladera(): Int = page.takeIf { it > 0 } ?: (board.pages - 1).takeIf { it > 0 } ?: 1

    fun showPage(page: Int) { this.page = page.coerceIn(0, board.pages - 1) }

    fun openWidgetMenu(id: Int) { widgetMenu = id }
    fun dismissWidgetMenu() { widgetMenu = null }

    /** The rows a widget is drawn at: the ones you chose, else its own. */
    fun widgetRows(id: Int): Int = board.placed(id)?.rows?.takeIf { it > 0 } ?: widgets.defaultRows(id)

    fun resizeWidget(id: Int, delta: Int) = saveBoard(board.resize(id, widgetRows(id) + delta))

    fun shiftWidget(id: Int, delta: Int) = saveBoard(board.shift(id, delta))

    /** Sends a widget to [page] (one past the last opens a new ladera) and shows you where it went. */
    fun moveWidget(id: Int, page: Int) {
        widgetMenu = null
        saveBoard(board.moveTo(id, page))
        showPage(board.placed(id)?.page ?: 0)
    }

    /** A widget dragged onto a page lands at [index] there; only pages (the camp and the laderas) take widgets. */
    fun dropWidget(id: Int, to: Zone, index: Int) {
        if (to is Zone.Ladera && !locked) saveBoard(board.insertWidget(id, to.page, index))
    }

    /** The name Android gives the app, to go back to. */
    fun originalLabel(packageName: String): String? = installed.find { it.packageName == packageName }?.label

    /** Gives the app [label]; blank, or its own name, goes back to that. */
    fun rename(packageName: String, label: String) {
        renaming = null
        val name = label.trim()
        names = if (name.isEmpty() || name == originalLabel(packageName)) names - packageName else names + (packageName to name)
        store.put(mapOf(KEY_NAMES to encodeNames(names)))
        apps = named()
    }

    fun cancelRename() {
        renaming = null
    }

    private fun named() = installed.map { app -> names[app.packageName]?.let { app.copy(label = it) } ?: app }

    fun openPinned(packageName: String, id: String) = actions.openShortcut(packageName, id)

    /** A held shortcut on a ladera: take it off, or see its app's info. */
    fun openShortcutMenu(packageName: String, id: String, label: String) {
        val app = apps.find { it.packageName == packageName } ?: return
        menu = OpenMenu(app, listOf(MenuEntry.UnpinShortcut(AppShortcut(id, label)), MenuEntry.Info), canReadShortcuts = true)
    }

    fun unpinShortcut(packageName: String, id: String) {
        saveBoard(board.removeShortcut(packageName, id))
        actions.pinShortcuts(packageName, board.shortcutsOf(packageName))
    }

    /** Reads the layout again: another screen (an app's "add to home screen") may have changed it meanwhile. */
    fun reload() {
        board = loadBoard()
    }

    fun removeWidget(id: Int) {
        widgetMenu = null
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

    private fun loadBoard() = WidgetBoard.decode(store.get(KEY_WIDGETS)).let { b -> WidgetBoard(b.items.filter { it !is Placed || widgets.exists(it.id) }) }

    private fun saveBoard(next: WidgetBoard) {
        board = next
        store.put(mapOf(KEY_WIDGETS to next.encode()))
    }

    private fun saveRecent(next: List<String>) {
        recent = next
        store.put(mapOf(KEY_RECENT to next.joinToString(",")))
    }

    private fun apply(change: HomeChange) {
        val next = change.home ?: return actions.say(change.refusal.orEmpty())
        home = next
        store.put(mapOf(KEY_PINNED to next.encodePinned(), KEY_HIDDEN to next.encodeHidden()) + (next.storedDock()?.let { mapOf(KEY_DOCK to it) } ?: emptyMap()))
    }

    companion object {
        const val KEY_DOCK = "dock"
        const val KEY_PINNED = "pinned"
        const val KEY_HIDDEN = "hidden"
        const val KEY_WIDGETS = "widgets"
        const val KEY_RECENT = "recent"
        const val KEY_NAMES = "names"
        const val KEY_LOCKED = "locked"

        private fun encodeNames(names: Map<String, String>) =
            names.entries.joinToString(",") { (pkg, name) -> pkg + "=" + java.net.URLEncoder.encode(name, "UTF-8") }

        private fun decodeNames(raw: String?): Map<String, String> = raw.orEmpty().split(",").mapNotNull { part ->
            val (pkg, name) = part.split("=", limit = 2).takeIf { it.size == 2 } ?: return@mapNotNull null
            pkg to java.net.URLDecoder.decode(name, "UTF-8")
        }.toMap()
        const val RECENT_MAX = 5
    }
}
