package dev.vivac.launcher.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.vivac.launcher.apps.AppSource
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.apps.Profile
import dev.vivac.launcher.campamento.Dock
import dev.vivac.launcher.campamento.Home
import dev.vivac.launcher.campamento.HomeChange
import dev.vivac.launcher.campamento.Placed
import dev.vivac.launcher.campamento.Shelved
import dev.vivac.launcher.campamento.WidgetBoard
import dev.vivac.launcher.petate.AppMenu
import dev.vivac.launcher.petate.AppShortcut
import dev.vivac.launcher.petate.FoundShortcut
import dev.vivac.launcher.petate.MenuEntry
import dev.vivac.launcher.widgets.WidgetOption

enum class Screen { CAMPAMENTO, PETATE, AJUSTES }

/** How apps are drawn: vivac's glyphs (the default), the system's themed icons, the apps' own, or a pack's. */
enum class IconStyle(val title: String) {
    GLYPHS("Glifos de vivac"),
    THEMED("Iconos temáticos"),
    ORIGINAL("Los de cada app"),
    PACK("Pack de iconos"),
}

/** One app's own icon, whatever the general style: vivac's glyph, the app's icon, or one drawable from a pack. */
sealed interface IconOverride {
    data object Glyph : IconOverride
    data object App : IconOverride
    data class Pack(val pack: String, val drawable: String) : IconOverride

    companion object {
        fun encode(o: IconOverride) = when (o) {
            Glyph -> "glyph"
            App -> "app"
            is Pack -> "pack:${o.pack}:${o.drawable}"
        }

        fun decode(raw: String): IconOverride? = when {
            raw == "glyph" -> Glyph
            raw == "app" -> App
            raw.startsWith("pack:") -> raw.removePrefix("pack:").split(":", limit = 2).takeIf { it.size == 2 }?.let { Pack(it[0], it[1]) }
            else -> null
        }
    }
}

/** An installed icon pack (ADW/Nova convention). */
data class IconPackInfo(val packageName: String, val label: String)

/** What a swipe on the camp does, as you choose it in vivac's settings. */
enum class Gesture(val title: String) {
    PETATE("Abrir el petate"),
    SEARCH("Buscar"),
    NOTIFICATIONS("Ver los avisos"),
    LOCK("Apagar la pantalla"),
    APP("Abrir una app"),
    NOTHING("Nada"),
}

/** Where an app sits on the home screen, as a drag sees it: picked up from one zone, dropped in another. */
sealed interface Zone {
    data object Dock : Zone
    data object Via : Zone
    data class Ladera(val page: Int) : Zone
    /** Not on the home screen yet (dragged in from the Petate). */
    data object Petate : Zone
    /** Into a folder on a ladera (dropped on it). */
    data class Folder(val id: String) : Zone
}

/** The two answers Android sends back while placing a widget. */
enum class WidgetStep { BIND, CONFIGURE }

data class OpenMenu(
    val app: InstalledApp,
    val entries: List<MenuEntry>,
    val canReadShortcuts: Boolean,
    /** The widgets this app offers, to add straight from its menu. */
    val widgets: List<WidgetOption> = emptyList(),
)

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
    /** Your contacts and calendars; none in tests that do not need them. */
    private val directory: Directory? = null,
) {
    var apps by mutableStateOf(emptyList<InstalledApp>()); private set
    var home by mutableStateOf(Home.decode(store.get(KEY_DOCK), store.get(KEY_PINNED), store.get(KEY_HIDDEN))); private set
    var board by mutableStateOf(loadBoard()); private set
    /** The home page in view: 0 is the Campamento, 1 onwards the laderas. */
    var page by mutableStateOf(0); private set
    /** The widget whose card is open (after a long press on it). */
    var editing by mutableStateOf<Int?>(null); private set
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

    /** Double tap on the camp's ground turns the screen off; off until you choose it. */
    var doubleTapLock by mutableStateOf(store.get(KEY_DOUBLE_TAP) == "1"); private set

    fun toggleDoubleTapLock() {
        campMenu = false
        doubleTapLock = !doubleTapLock
        store.put(mapOf(KEY_DOUBLE_TAP to if (doubleTapLock) "1" else "0"))
        if (doubleTapLock && !actions.lockScreenReady()) askForLockService()
    }

    fun onDoubleTap() {
        if (doubleTapLock && !actions.lockScreen()) askForLockService()
    }

    private fun askForLockService() {
        actions.say("Para apagar la pantalla con doble toque, activa «vivac» en Accesibilidad. Solo apaga la pantalla; no lee nada.")
        actions.accessibilitySettings()
    }

    /** The phone's wallpaper behind the camp (under vivac's night veil), or the plain night ground. */
    var showWallpaper by mutableStateOf(store.get(KEY_WALLPAPER) == "1"); private set

    fun toggleWallpaper() {
        campMenu = false
        showWallpaper = !showWallpaper
        store.put(mapOf(KEY_WALLPAPER to if (showWallpaper) "1" else "0"))
    }

    fun changeWallpaper() {
        campMenu = false
        actions.pickWallpaper()
    }

    /** Columns in the Petate's grid: 4 or 5. */
    var columns by mutableStateOf(store.get(KEY_COLUMNS)?.toIntOrNull()?.coerceIn(4, 5) ?: 4); private set
    /** Names under the tiles. */
    var labels by mutableStateOf(store.get(KEY_LABELS) != "0"); private set
    /** How many notifications, instead of a plain dot. */
    var showCounts by mutableStateOf(store.get(KEY_COUNTS) == "1"); private set
    var swipeUp by mutableStateOf(gesture(KEY_SWIPE_UP, Gesture.PETATE)); private set
    var swipeDown by mutableStateOf(gesture(KEY_SWIPE_DOWN, Gesture.NOTIFICATIONS)); private set

    var iconStyle by mutableStateOf(IconStyle.entries.firstOrNull { it.name == store.get(KEY_ICONS) } ?: IconStyle.GLYPHS); private set
    /** The pack used when [iconStyle] is [IconStyle.PACK]. */
    var iconPack by mutableStateOf(store.get(KEY_ICON_PACK)?.takeIf { it.isNotBlank() }); private set

    /** Icons you chose app by app (from its menu). */
    var iconFor by mutableStateOf(decodeIcons(store.get(KEY_ICON_FOR))); private set
    /** The app whose icon you are choosing. */
    var iconPicker by mutableStateOf<InstalledApp?>(null); private set

    fun cancelIconPicker() { iconPicker = null }

    /** [icon] null: back to the general style. */
    fun setIcon(packageName: String, icon: IconOverride?) {
        iconPicker = null
        iconFor = if (icon == null) iconFor - packageName else iconFor + (packageName to icon)
        store.put(mapOf(KEY_ICON_FOR to iconFor.entries.joinToString(",") { (p, o) -> p + "=" + IconOverride.encode(o) }))
    }

    private fun decodeIcons(raw: String?): Map<String, IconOverride> = raw.orEmpty().split(",").mapNotNull { part ->
        val (pkg, value) = part.split("=", limit = 2).takeIf { it.size == 2 } ?: return@mapNotNull null
        IconOverride.decode(value)?.let { pkg to it }
    }.toMap()

    fun chooseIcons(style: IconStyle) {
        iconStyle = style
        store.put(mapOf(KEY_ICONS to style.name))
    }

    fun chooseIconPack(packageName: String) {
        iconPack = packageName
        iconStyle = IconStyle.PACK
        store.put(mapOf(KEY_ICON_PACK to packageName, KEY_ICONS to IconStyle.PACK.name))
    }

    private fun gesture(key: String, default: Gesture) = Gesture.entries.firstOrNull { it.name == store.get(key) } ?: default

    /** The Petate's search also looks through your contacts, and your calendars. Off until you choose. */
    var searchContacts by mutableStateOf(store.get(KEY_CONTACTS) == "1"); private set
    var searchCalendar by mutableStateOf(store.get(KEY_CALENDAR) == "1"); private set

    fun toggleContacts() {
        searchContacts = !searchContacts
        store.put(mapOf(KEY_CONTACTS to if (searchContacts) "1" else "0"))
        if (searchContacts && directory?.canReadContacts() == false) directory.askContacts()
    }

    fun toggleCalendar() {
        searchCalendar = !searchCalendar
        store.put(mapOf(KEY_CALENDAR to if (searchCalendar) "1" else "0"))
        if (searchCalendar && directory?.canReadCalendar() == false) directory.askCalendar()
    }

    fun findContacts(query: String): List<Contact> {
        val d = directory ?: return emptyList()
        if (!searchContacts || query.isBlank() || !d.canReadContacts()) return emptyList()
        return d.contacts(query.trim()).take(3)
    }

    fun findEvents(query: String): List<CalendarEvent> {
        val d = directory ?: return emptyList()
        if (!searchCalendar || query.isBlank() || !d.canReadCalendar()) return emptyList()
        return d.events(query.trim()).take(3)
    }

    fun openContact(contact: Contact) { directory?.openContact(contact); screen = Screen.CAMPAMENTO }
    fun openEvent(event: CalendarEvent) { directory?.openEvent(event); screen = Screen.CAMPAMENTO }

    fun openSettings() {
        campMenu = false
        screen = Screen.AJUSTES
    }

    fun chooseColumns(n: Int) {
        columns = n.coerceIn(4, 5)
        store.put(mapOf(KEY_COLUMNS to columns.toString()))
    }

    fun toggleLabels() {
        labels = !labels
        store.put(mapOf(KEY_LABELS to if (labels) "1" else "0"))
    }

    fun toggleCounts() {
        showCounts = !showCounts
        store.put(mapOf(KEY_COUNTS to if (showCounts) "1" else "0"))
    }

    /** The app a swipe opens when its gesture is [Gesture.APP]. */
    var swipeUpApp by mutableStateOf(store.get(KEY_SWIPE_UP_APP)); private set
    var swipeDownApp by mutableStateOf(store.get(KEY_SWIPE_DOWN_APP)); private set

    fun chooseSwipeUp(g: Gesture, app: String? = swipeUpApp) {
        swipeUp = g; swipeUpApp = app
        store.put(mapOf(KEY_SWIPE_UP to g.name, KEY_SWIPE_UP_APP to app.orEmpty()))
    }

    fun chooseSwipeDown(g: Gesture, app: String? = swipeDownApp) {
        swipeDown = g; swipeDownApp = app
        store.put(mapOf(KEY_SWIPE_DOWN to g.name, KEY_SWIPE_DOWN_APP to app.orEmpty()))
    }

    fun onSwipeUp() = perform(swipeUp, swipeUpApp)
    fun onSwipeDown() = perform(swipeDown, swipeDownApp)

    private fun perform(g: Gesture, app: String? = null) {
        when (g) {
            Gesture.PETATE -> openPetate(false)
            Gesture.SEARCH -> openPetate(true)
            Gesture.NOTIFICATIONS -> actions.showNotifications()
            Gesture.LOCK -> if (!actions.lockScreen()) askForLockService()
            Gesture.APP -> app?.takeIf { pkg -> apps.any { it.packageName == pkg } }?.let(::openApp)
            Gesture.NOTHING -> Unit
        }
    }

    fun toggleLock() {
        campMenu = false
        locked = !locked
        store.put(mapOf(KEY_LOCKED to if (locked) "1" else "0"))
        actions.say(if (locked) "Campamento bloqueado: nada se mueve hasta que lo desbloquees." else "Campamento desbloqueado.")
    }

    /** The phone's work profile and private space, as of the last refresh. */
    var profiles by mutableStateOf(emptyList<Profile>()); private set

    fun openInProfile(packageName: String, profile: Long) {
        actions.openInProfile(packageName, profile)
        screen = Screen.CAMPAMENTO
    }

    fun lockProfile(profile: Profile) = actions.lockProfile(profile.id, !profile.locked)

    fun refresh() {
        installed = source.installed()
        apps = named()
        profiles = source.profiles()
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
        Dock.pick(visibleApps().map { it.packageName }.toSet(), home.dock, home.dockChosen)

    /** The shortcuts the Petate's search looks through, gathered each time it opens. */
    var petateShortcuts by mutableStateOf(emptyList<FoundShortcut>()); private set

    fun openShortcutFromPetate(found: FoundShortcut) {
        actions.openShortcut(found.app.packageName, found.shortcut.id)
        screen = Screen.CAMPAMENTO
    }

    fun openPetate(search: Boolean) {
        val visible = visibleApps().associateBy { it.packageName }
        petateShortcuts = actions.allShortcuts().mapNotNull { (pkg, s) -> visible[pkg]?.let { FoundShortcut(it, s) } }
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
        if (editing != null) { editing = null; return true }
        if (screen == Screen.CAMPAMENTO) return false
        screen = Screen.CAMPAMENTO
        return true
    }

    /** Pressing Home while vivac is in front: close whatever is open and return to the camp. */
    fun onHomePressed() {
        menu = null
        campMenu = false
        picker = null
        editing = null
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
        menu = OpenMenu(app, entries, actions.canReadShortcuts(), widgets.options().filter { it.appPackage == packageName })
    }

    fun dismissMenu() { menu = null }

    /** A widget picked from an app's menu: placed like one from the camp's picker. */
    fun addWidgetFromMenu(option: WidgetOption) {
        menu = null
        addWidget(option)
    }

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
            MenuEntry.ToFolder -> folderPicker = app
            MenuEntry.ChangeIcon -> iconPicker = app
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

    fun backUp() {
        campMenu = false
        actions.backUp()
    }

    fun askRestore() {
        campMenu = false
        actions.pickBackup()
    }

    fun exportLayout(): String = Backup.export(store)

    /** Puts a copy back: every choice it holds replaces the current one, this phone's widgets stay. */
    fun restoreLayout(text: String) {
        if (!Backup.restore(text, store)) return actions.say("Ese archivo no es una copia del campamento de vivac.")
        home = Home.decode(store.get(KEY_DOCK), store.get(KEY_PINNED), store.get(KEY_HIDDEN))
        board = loadBoard()
        recent = store.get(KEY_RECENT).orEmpty().split(",").filter { it.isNotBlank() }
        names = decodeNames(store.get(KEY_NAMES))
        locked = store.get(KEY_LOCKED) == "1"
        doubleTapLock = store.get(KEY_DOUBLE_TAP) == "1"
        showWallpaper = store.get(KEY_WALLPAPER) == "1"
        columns = store.get(KEY_COLUMNS)?.toIntOrNull()?.coerceIn(4, 5) ?: 4
        labels = store.get(KEY_LABELS) != "0"
        showCounts = store.get(KEY_COUNTS) == "1"
        swipeUp = gesture(KEY_SWIPE_UP, Gesture.PETATE)
        swipeDown = gesture(KEY_SWIPE_DOWN, Gesture.NOTIFICATIONS)
        swipeUpApp = store.get(KEY_SWIPE_UP_APP)
        swipeDownApp = store.get(KEY_SWIPE_DOWN_APP)
        iconStyle = IconStyle.entries.firstOrNull { it.name == store.get(KEY_ICONS) } ?: IconStyle.GLYPHS
        iconPack = store.get(KEY_ICON_PACK)?.takeIf { it.isNotBlank() }
        iconFor = decodeIcons(store.get(KEY_ICON_FOR))
        refresh()
        actions.say("Campamento restaurado.")
    }

    fun becomeHome() {
        campMenu = false
        actions.askToBeHome()
    }

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
            is Zone.Folder -> Unit
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
            is Zone.Folder -> next = next.addToFolder(to.id, packageName)
        }
        val dockTouched = from == Zone.Dock || to == Zone.Dock
        apply(HomeChange(home.copy(dock = if (dockTouched) dock else home.dock, pinned = pinned, dockChosen = home.dockChosen || dockTouched)))
        if (next != board) saveBoard(next)
    }

    private fun position(packageName: String, zone: Zone): Int = when (zone) {
        Zone.Dock -> shownDock().indexOf(packageName)
        Zone.Via -> home.pinned.indexOf(packageName)
        is Zone.Ladera -> board.onPage(zone.page).indexOfFirst { it is Shelved && it.packageName == packageName }
        Zone.Petate, is Zone.Folder -> -1
    }

    /** The ladera an app goes to: the one in view, else the last one, else a new one. */
    private fun ladera(): Int = page.takeIf { it > 0 } ?: (board.pages - 1).takeIf { it > 0 } ?: 1

    /** Shows [page]: the camp, a ladera, or the empty one past the last, where a new ladera starts. */
    fun showPage(page: Int) { this.page = page.coerceIn(0, board.pages) }

    /** The ladera the app picker is adding to, while it is open. */
    var addingTo by mutableStateOf<Int?>(null); private set

    /** Opens the app picker for the ladera in view; the camp has its own route and dock. */
    fun openAdder() { addingTo = page.takeIf { it > 0 } }

    fun closeAdder() { addingTo = null }

    /** Puts an app on the ladera being added to, or takes it off if it is there already. */
    fun toggleOnLadera(packageName: String) {
        val at = addingTo ?: return
        saveBoard(if (Shelved(packageName, at) in board.items) board.removeApp(packageName) else board.addApp(packageName, at))
        // Emptied, the ladera is gone: the picker stays on the empty one at the end.
        addingTo = at.coerceAtMost(board.pages)
    }

    fun editWidget(id: Int) { editing = id }
    fun stopEditing() { editing = null }

    /** The rows a widget is drawn at: the ones you chose, else its own. */
    fun widgetRows(id: Int): Int = board.placed(id)?.rows?.takeIf { it > 0 } ?: widgets.defaultRows(id)

    fun resizeWidget(id: Int, delta: Int) = saveBoard(board.resize(id, widgetRows(id) + delta))

    fun shiftWidget(id: Int, delta: Int) = saveBoard(board.shift(id, delta))

    /** Sends a widget to [page] (one past the last opens a new ladera) and shows you where it went. */
    fun moveWidget(id: Int, page: Int) {
        editing = null
        saveBoard(board.moveTo(id, page))
        showPage(board.placed(id)?.page ?: 0)
    }

    /** A shortcut or folder dragged onto a ladera lands at [index] there. */
    fun moveItem(item: dev.vivac.launcher.campamento.Item, to: Zone, index: Int) {
        if (to is Zone.Ladera && !locked) saveBoard(board.moveItem(item, to.page, index))
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

    /** The app being put in a folder: the sheet that lists folders, or makes one. */
    var folderPicker by mutableStateOf<InstalledApp?>(null); private set
    /** The folder open on screen. */
    var openFolder by mutableStateOf<String?>(null); private set

    fun cancelFolderPicker() { folderPicker = null }

    /** A new folder with the app, in its place on a ladera or on the one in view; it opens to be named. */
    fun newFolder(packageName: String) {
        folderPicker = null
        saveBoard(board.newFolder("Carpeta", packageName, ladera()).let { it.withoutDockAndVia(packageName) })
        openFolder = board.folderOf(packageName)?.id
    }

    fun putInFolder(packageName: String, id: String) {
        folderPicker = null
        saveBoard(board.addToFolder(id, packageName).withoutDockAndVia(packageName))
    }

    /** An app in a folder lives there alone: it leaves the dock and the route. */
    private fun WidgetBoard.withoutDockAndVia(packageName: String): WidgetBoard {
        val inDock = packageName in shownDock()
        if (inDock || packageName in home.pinned) {
            apply(HomeChange(home.copy(dock = if (inDock) shownDock() - packageName else home.dock, pinned = home.pinned - packageName, dockChosen = home.dockChosen || inDock)))
        }
        return this
    }

    fun openFolder(id: String) { if (board.folder(id) != null) openFolder = id }
    fun closeFolder() { openFolder = null }

    fun renameFolder(id: String, name: String) {
        if (name.isNotBlank()) saveBoard(board.renameFolder(id, name.trim()))
    }

    fun takeOutOfFolder(id: String, packageName: String) {
        saveBoard(board.removeFromFolder(id, packageName))
        if (board.folder(id) == null) openFolder = null
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
        editing = null
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
        const val KEY_DOUBLE_TAP = "doubleTapLock"
        const val KEY_WALLPAPER = "wallpaper"
        const val KEY_COLUMNS = "columns"
        const val KEY_LABELS = "labels"
        const val KEY_COUNTS = "counts"
        const val KEY_SWIPE_UP = "swipeUp"
        const val KEY_SWIPE_DOWN = "swipeDown"
        const val KEY_SWIPE_UP_APP = "swipeUpApp"
        const val KEY_SWIPE_DOWN_APP = "swipeDownApp"
        const val KEY_ICONS = "icons"
        const val KEY_CONTACTS = "searchContacts"
        const val KEY_CALENDAR = "searchCalendar"
        const val KEY_ICON_PACK = "iconPack"
        const val KEY_ICON_FOR = "iconFor"

        private fun encodeNames(names: Map<String, String>) =
            names.entries.joinToString(",") { (pkg, name) -> pkg + "=" + java.net.URLEncoder.encode(name, "UTF-8") }

        private fun decodeNames(raw: String?): Map<String, String> = raw.orEmpty().split(",").mapNotNull { part ->
            val (pkg, name) = part.split("=", limit = 2).takeIf { it.size == 2 } ?: return@mapNotNull null
            pkg to java.net.URLDecoder.decode(name, "UTF-8")
        }.toMap()
        const val RECENT_MAX = 5
    }
}
