package dev.vivac.launcher.core

import android.content.Context
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.CompositionLocalProvider
import dev.vivac.launcher.ajustes.SettingsActions
import dev.vivac.launcher.ajustes.SettingsScreen
import dev.vivac.launcher.ajustes.SettingsState
import dev.vivac.launcher.theme.LocalLabels
import dev.vivac.launcher.theme.LocalShowCounts
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import dev.vivac.launcher.campamento.DragBoard
import dev.vivac.launcher.campamento.Folder
import dev.vivac.launcher.campamento.FolderPickSheet
import dev.vivac.launcher.campamento.FolderSheet
import dev.vivac.launcher.campamento.CampamentoScreen
import dev.vivac.launcher.campamento.PhoneFacts
import dev.vivac.launcher.petate.AppMenuSheet
import dev.vivac.launcher.petate.PetateScreen
import dev.vivac.launcher.petate.RenameSheet
import dev.vivac.launcher.widgets.CampMenuSheet
import dev.vivac.launcher.widgets.Grip
import dev.vivac.launcher.widgets.PlacedWidget
import dev.vivac.launcher.widgets.WidgetPickerSheet

/** How placed widgets are drawn: their height and their live view (Android's AppWidgetHostView in production). */
interface WidgetViews {
    /** Drawn height for [rows] (0: the widget's own size). */
    fun heightDp(id: Int, rows: Int): Int
    /** The live view; a finger held on it goes to [grip]. */
    fun view(context: Context, id: Int, widthDp: Float, rows: Int, grip: Grip): View?
}

/** The whole launcher on screen, driven by [launcher]. */
@Composable
fun LauncherApp(
    launcher: Launcher,
    stamp: String,
    facts: PhoneFacts,
    actions: Actions,
    widgetViews: WidgetViews,
    /** Shared with the activity, which answers Android's swipe-home animation with a tile's place. */
    drag: DragBoard = remember { DragBoard() },
    /** The phone's connections, shown top right on the camp. */
    status: dev.vivac.launcher.campamento.PhoneStatus = dev.vivac.launcher.campamento.PhoneStatus(),
) {
    BackHandler(enabled = launcher.canGoBack) { launcher.back() }
    // The phone's notices, for the shade and for vivac's chats widgets.
    val noNoticesHere = remember { kotlinx.coroutines.flow.MutableStateFlow(emptyList<dev.vivac.launcher.avisos.Aviso>()) }
    val allAvisos by (launcher.notices?.live ?: noNoticesHere).collectAsState()
    // Notification access is granted in Android's settings: read it again each time vivac comes back to the front.
    // A count, not the lifecycle state: no frame is drawn while vivac is away, so the state would come back unchanged.
    var resumes by remember { androidx.compose.runtime.mutableIntStateOf(0) }
    androidx.lifecycle.compose.LifecycleEventEffect(androidx.lifecycle.Lifecycle.Event.ON_RESUME) { resumes++ }
    val dotsAllowed = remember(resumes) { actions.dotsAllowed() }
    // On the camp the status bar hides, so a pull from the top edge reaches vivac (and opens its shade); a swipe
    // there brings Android's bar back for a moment. Everywhere else the bar shows as usual.
    val view = androidx.compose.ui.platform.LocalView.current
    val hideBar = launcher.hidesStatusBar
    androidx.compose.runtime.LaunchedEffect(hideBar) {
        val window = (view.context as? android.app.Activity)?.window ?: return@LaunchedEffect
        val bars = androidx.core.view.WindowCompat.getInsetsController(window, view)
        bars.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        val status = androidx.core.view.WindowInsetsCompat.Type.statusBars()
        if (hideBar) bars.hide(status) else bars.show(status)
    }
    // Android draws the wallpaper behind a window that asks for it; vivac's camp then lets it show through.
    val window = (androidx.compose.ui.platform.LocalContext.current as? android.app.Activity)?.window
    androidx.compose.runtime.LaunchedEffect(launcher.showWallpaper) {
        if (launcher.showWallpaper) {
            window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER)
            window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(android.graphics.Color.TRANSPARENT))
        } else {
            window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER)
            window?.setBackgroundDrawableResource(dev.vivac.launcher.R.color.noche_900)
        }
    }
    val camp: @Composable () -> Unit = {
        CampamentoScreen(
            stamp = stamp,
            facts = facts,
            apps = launcher.visibleApps(),
            home = launcher.home,
            onOpenApp = launcher::openApp,
            onAppMenu = launcher::openMenu,
            onOpenPetate = launcher::openPetate,
            onOpenSettings = launcher::openSystem,
            onOpenAbout = actions::securityUpdates,
            onShowNotifications = actions::showNotifications,
            board = launcher.board,
            page = launcher.page,
            onPage = launcher::showPage,
            widgetHeightDp = widgetViews::heightDp,
            widgetView = widgetViews::view,
            onEditWidget = launcher::editWidget,
            editing = launcher.editing,
            widgetRows = launcher::widgetRows,
            onResizeWidget = launcher::resizeWidget,
            onStopEditing = launcher::stopEditing,
            onDrop = launcher::drop,
            onCampMenu = launcher::openCampMenu,
            drag = drag,
            onWidgetDrop = launcher::dropWidget,
            widgetLabel = { id -> launcher.placedWidgets().firstOrNull { it.id == id }?.label ?: "widget" },
            onShortcut = { launcher.openPinned(it.packageName, it.id) },
            onShortcutMenu = { launcher.openShortcutMenu(it.packageName, it.id, it.label) },
            locked = launcher.locked,
            onDoubleTap = launcher::onDoubleTap,
            wallpaper = launcher.showWallpaper,
            veil = launcher.veil.alpha,
            onOpenFolder = launcher::openFolder,
            onSwipeUp = launcher::onSwipeUp,
            onSwipeDown = launcher::onSwipeDown,
            onMoveItem = launcher::moveItem,
            onAddApps = launcher::openAdder,
            tintWidgets = launcher.tintWidgets,
            onOpenAvisos = launcher::openAvisos,
            status = status,
            // Every app with notices, the system's own included (named as Android names them).
            noticeApps = allAvisos.filter { !it.ongoing && !it.summary }.sortedByDescending { it.postedAt }.distinctBy { it.packageName }
                .map { a -> launcher.apps.find { it.packageName == a.packageName } ?: dev.vivac.launcher.apps.InstalledApp(a.appLabel.ifBlank { "Sistema" }, a.packageName, isSystem = true) },
            vivacWidget = { id, _ ->
                when (val w = launcher.vivacWidget(id)) {
                    is dev.vivac.launcher.campamento.VivacWidget.Chats -> dev.vivac.launcher.widgets.ChatsWidget(
                        app = launcher.apps.find { it.packageName == w.packageName },
                        packageName = w.packageName,
                        avisos = allAvisos,
                        now = System.currentTimeMillis(),
                        onOpen = launcher::openAviso,
                        onOpenApp = { launcher.openApp(w.packageName) },
                    )
                    is dev.vivac.launcher.campamento.VivacWidget.Atajos -> {
                        val shortcuts = remember(w.packageName) { launcher.shortcutsOf(w.packageName) }
                        dev.vivac.launcher.widgets.AtajosWidget(
                            app = launcher.apps.find { it.packageName == w.packageName },
                            shortcuts = shortcuts,
                            onShortcut = { s -> launcher.openPinned(w.packageName, s) },
                            onOpenApp = { launcher.openApp(w.packageName) },
                        )
                    }
                    null -> Unit
                }
            },
        )
    }
    CompositionLocalProvider(
        LocalLabels provides launcher.labels,
        LocalShowCounts provides launcher.showCounts,
        dev.vivac.launcher.apps.LocalIconChoice provides dev.vivac.launcher.apps.IconChoice(launcher.iconStyle, launcher.iconPack),
        dev.vivac.launcher.apps.LocalIconOverrides provides launcher.iconFor,
    ) {
    AnimatedContent(launcher.screen, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "screen") { current ->
        when (current) {
            Screen.CAMPAMENTO -> camp()
            Screen.AJUSTES -> SettingsScreen(
                SettingsState(
                    locked = launcher.locked, wallpaper = launcher.showWallpaper, labels = launcher.labels, tintWidgets = launcher.tintWidgets, columns = launcher.columns,
                    dotsAllowed = dotsAllowed, counts = launcher.showCounts, swipeUp = launcher.swipeUp, swipeDown = launcher.swipeDown,
                    doubleTapLock = launcher.doubleTapLock, isHome = actions.isHome(),
                    iconStyle = launcher.iconStyle, iconPack = launcher.iconPack, packs = actions.iconPacks(),
                    contacts = launcher.searchContacts, calendar = launcher.searchCalendar, protectHidden = launcher.protectHidden, veil = launcher.veil,
                    apps = launcher.visibleApps(), swipeUpApp = launcher.swipeUpApp, swipeDownApp = launcher.swipeDownApp,
                ),
                SettingsActions(
                    toggleLock = launcher::toggleLock, toggleWallpaper = launcher::toggleWallpaper, changeWallpaper = launcher::changeWallpaper,
                    paintLock = launcher::paintLockScreen, restoreLock = launcher::restoreLockScreen, toggleProtectHidden = launcher::toggleProtectHidden, chooseVeil = launcher::chooseVeil,
                    toggleLabels = launcher::toggleLabels, toggleTintWidgets = launcher::toggleTintWidgets, setColumns = launcher::chooseColumns, allowDots = launcher::allowDots,
                    toggleCounts = launcher::toggleCounts, setSwipeUp = launcher::chooseSwipeUp, setSwipeDown = launcher::chooseSwipeDown,
                    toggleDoubleTap = launcher::toggleDoubleTapLock, backUp = launcher::backUp, restore = launcher::askRestore,
                    becomeHome = launcher::becomeHome, close = { launcher.back() },
                    chooseIcons = launcher::chooseIcons, chooseIconPack = launcher::chooseIconPack,
                    toggleContacts = launcher::toggleContacts, toggleCalendar = launcher::toggleCalendar,
                ),
            )
            Screen.AVISOS -> {
                dev.vivac.launcher.avisos.AvisosScreen(
                    avisos = allAvisos,
                    apps = launcher.apps,
                    now = System.currentTimeMillis(),
                    quick = launcher.quick,
                    isOn = launcher::isOn,
                    editing = launcher.editingQuick,
                    brightness = launcher.brightness,
                    act = dev.vivac.launcher.avisos.AvisosActions(
                        open = launcher::openAviso, dismiss = launcher::dismissAviso, dismissAll = launcher::dismissAllAvisos,
                        reply = launcher::replyAviso, run = launcher::runQuick, edit = launcher::toggleQuickEditing,
                        add = launcher::addQuick, remove = launcher::removeQuick, move = launcher::moveQuick, pickApps = launcher::openQuickApps, brightness = launcher::changeBrightness,
                        dismissApp = launcher::dismissApp, noticeSettings = launcher::noticeSettings, close = { launcher.back() },
                    ),
                )
            }
            Screen.SISTEMA -> dev.vivac.launcher.ajustes.SystemScreen(
                facts = "BATERÍA ${facts.batteryPercent} %${if (facts.charging) " · CARGANDO" else ""} · LIBRE ${facts.freeGb} DE ${facts.totalGb} GB",
                onPage = launcher::openSystemPage,
                onVivac = launcher::openSettings,
                onClose = { launcher.back() },
            )
            Screen.PETATE -> Box {
                // An app lifted out of the petate is carried over the camp: the camp comes up underneath and the
                // petate goes see-through, staying in place so the finger keeps its hold on the tile.
                val lifted = drag.held?.from == Zone.Petate
                if (lifted) camp()
                PetateScreen(
                    apps = launcher.apps,
                    hidden = launcher.home.hidden.toSet(),
                    focusSearch = launcher.focusSearch,
                    onOpenApp = launcher::openFromPetate,
                    onAppMenu = launcher::openMenu,
                    recent = launcher.visibleRecent().mapNotNull { pkg -> launcher.apps.find { it.packageName == pkg } },
                    drag = drag,
                    onDrop = { h, spot -> launcher.drop(h.app.packageName, h.from, spot.zone, spot.index) },
                    onLand = { launcher.back() },
                    onCopy = actions::copy,
                    onWebSearch = actions::webSearch,
                    onStoreSearch = actions::storeSearch,
                    shortcuts = launcher.petateShortcuts,
                    onOpenShortcut = launcher::openShortcutFromPetate,
                    onOpenSettingsPage = launcher::openSettingsPage,
                    askToSeeHidden = launcher::seeHidden,
                    searches = launcher.searches, onSearched = launcher::recordSearch, onClearSearches = launcher::clearSearches,
                    profiles = launcher.profiles,
                    columns = launcher.columns,
                    findContacts = launcher::findContacts,
                    findEvents = launcher::findEvents,
                    onOpenContact = launcher::openContact,
                    onOpenEvent = launcher::openEvent,
                    onOpenInProfile = launcher::openInProfile,
                    onLockProfile = launcher::lockProfile,
                    modifier = Modifier.graphicsLayer { alpha = if (lifted) 0f else 1f },
                )
            }
        }
    }
    }
    if (launcher.campMenu) {
        CampMenuSheet(
            placed = launcher.placedWidgets().map { PlacedWidget(it.id, it.label) },
            dotsAllowed = dotsAllowed,
            onAdd = launcher::showPicker,
            onRemove = launcher::removeWidget,
            onAllowDots = launcher::allowDots,
            locked = launcher.locked,
            onToggleLock = launcher::toggleLock,
            doubleTapLock = launcher.doubleTapLock,
            onToggleDoubleTap = launcher::toggleDoubleTapLock,
            isHome = actions.isHome(),
            onBecomeHome = launcher::becomeHome,
            onBackUp = launcher::backUp,
            onSettings = launcher::openSettings,
            onRestore = launcher::askRestore,
            showWallpaper = launcher.showWallpaper,
            onToggleWallpaper = launcher::toggleWallpaper,
            onChangeWallpaper = launcher::changeWallpaper,
            onDismiss = launcher::dismissCampMenu,
        )
    }
    launcher.picker?.let { options ->
        WidgetPickerSheet(options, onPick = launcher::addWidget, onDismiss = launcher::dismissPicker)
    }
    launcher.addingTo?.let { at ->
        dev.vivac.launcher.campamento.PickAppsSheet(
            heading = "AÑADIR A LA LADERA $at",
            title = "Toca las apps que quieres aquí",
            apps = launcher.visibleApps(),
            chosen = launcher.board.onPage(at).filterIsInstance<dev.vivac.launcher.campamento.Shelved>().map { it.packageName }.toSet(),
            chosenLabel = "en esta ladera",
            onToggle = launcher::toggleOnLadera,
            onDismiss = launcher::closeAdder,
        )
    }
    if (launcher.pickingQuickApps) {
        dev.vivac.launcher.campamento.PickAppsSheet(
            heading = "ATAJOS DE LA CORTINA",
            title = "Toca las apps que quieres como atajo",
            apps = launcher.visibleApps(),
            chosen = launcher.quick.filterIsInstance<dev.vivac.launcher.avisos.Quick.App>().map { it.packageName }.toSet(),
            chosenLabel = "en la cortina",
            onToggle = launcher::toggleQuickApp,
            onDismiss = launcher::closeQuickApps,
        )
    }
    launcher.folderPicker?.let { app ->
        FolderPickSheet(
            app = app,
            folders = launcher.board.items.filterIsInstance<Folder>(),
            onPick = { launcher.putInFolder(app.packageName, it) },
            onNew = { launcher.newFolder(app.packageName) },
            onDismiss = launcher::cancelFolderPicker,
        )
    }
    launcher.openFolder?.let { id ->
        val folder = launcher.board.folder(id) ?: return@let
        FolderSheet(
            folder = folder,
            apps = folder.apps.mapNotNull { pkg -> launcher.visibleApps().find { it.packageName == pkg } },
            onOpenApp = { launcher.closeFolder(); launcher.openApp(it) },
            onTakeOut = { launcher.takeOutOfFolder(id, it) },
            onRename = { launcher.renameFolder(id, it) },
            onDismiss = launcher::closeFolder,
        )
    }
    launcher.iconPicker?.let { app ->
        dev.vivac.launcher.apps.IconPickerSheet(
            app = app,
            current = launcher.iconFor[app.packageName],
            packs = actions.iconPacks(),
            onPick = { launcher.setIcon(app.packageName, it) },
            onDismiss = launcher::cancelIconPicker,
        )
    }
    launcher.renaming?.let { app ->
        RenameSheet(
            current = app.label,
            original = launcher.originalLabel(app.packageName) ?: app.label,
            onSave = { launcher.rename(app.packageName, it) },
            onDismiss = launcher::cancelRename,
        )
    }
    launcher.menu?.let { m ->
        AppMenuSheet(
            app = m.app,
            entries = m.entries,
            canReadShortcuts = m.canReadShortcuts,
            onDismiss = launcher::dismissMenu,
            onPick = launcher::pick,
            widgets = m.widgets,
            onAddWidget = launcher::addWidgetFromMenu,
        )
    }
}
