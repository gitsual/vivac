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
import dev.vivac.launcher.widgets.WidgetMenuSheet

/** How placed widgets are drawn: their height and their live view (Android's AppWidgetHostView in production). */
interface WidgetViews {
    /** Drawn height for [rows] (0: the widget's own size). */
    fun heightDp(id: Int, rows: Int): Int
    /** The live view; a finger held on it goes to [grip]. */
    fun view(context: Context, id: Int, widthDp: Float, rows: Int, grip: Grip): View?
}

/** The whole launcher on screen, driven by [launcher]. */
@Composable
fun LauncherApp(launcher: Launcher, stamp: String, facts: PhoneFacts, actions: Actions, widgetViews: WidgetViews) {
    BackHandler(enabled = launcher.screen == Screen.PETATE) { launcher.back() }
    val drag = remember { DragBoard() }
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
            onOpenSettings = actions::systemSettings,
            onOpenAbout = actions::securityUpdates,
            onShowNotifications = actions::showNotifications,
            board = launcher.board,
            page = launcher.page,
            onPage = launcher::showPage,
            widgetHeightDp = widgetViews::heightDp,
            widgetView = widgetViews::view,
            onWidgetMenu = launcher::openWidgetMenu,
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
            onOpenFolder = launcher::openFolder,
        )
    }
    AnimatedContent(launcher.screen, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "screen") { current ->
        when (current) {
            Screen.CAMPAMENTO -> camp()
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
                    profiles = launcher.profiles,
                    onOpenInProfile = launcher::openInProfile,
                    onLockProfile = launcher::lockProfile,
                    modifier = Modifier.graphicsLayer { alpha = if (lifted) 0f else 1f },
                )
            }
        }
    }
    if (launcher.campMenu) {
        CampMenuSheet(
            placed = launcher.placedWidgets().map { PlacedWidget(it.id, it.label) },
            dotsAllowed = actions.dotsAllowed(),
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
    launcher.widgetMenu?.let { id ->
        val placed = launcher.board.placed(id) ?: return@let
        val onPage = launcher.board.onPage(placed.page)
        WidgetMenuSheet(
            label = launcher.placedWidgets().firstOrNull { it.id == id }?.label ?: "widget",
            rows = launcher.widgetRows(id),
            page = placed.page,
            pages = launcher.board.pages,
            first = onPage.firstOrNull() == placed,
            last = onPage.lastOrNull() == placed,
            onResize = { launcher.resizeWidget(id, it) },
            onShift = { launcher.shiftWidget(id, it) },
            onMove = { launcher.moveWidget(id, it) },
            onRemove = { launcher.removeWidget(id) },
            onDismiss = launcher::dismissWidgetMenu,
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
