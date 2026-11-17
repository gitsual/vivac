package dev.vivac.launcher.core

import android.content.Context
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import dev.vivac.launcher.campamento.CampamentoScreen
import dev.vivac.launcher.campamento.PhoneFacts
import dev.vivac.launcher.petate.AppMenuSheet
import dev.vivac.launcher.petate.PetateScreen
import dev.vivac.launcher.widgets.CampMenuSheet
import dev.vivac.launcher.widgets.PlacedWidget
import dev.vivac.launcher.widgets.WidgetPickerSheet

/** How placed widgets are drawn: their height and their live view (Android's AppWidgetHostView in production). */
interface WidgetViews {
    fun heightDp(id: Int): Int
    fun view(context: Context, id: Int, widthDp: Float): View?
}

/** The whole launcher on screen, driven by [launcher]. */
@Composable
fun LauncherApp(launcher: Launcher, stamp: String, facts: PhoneFacts, actions: Actions, widgetViews: WidgetViews) {
    BackHandler(enabled = launcher.screen == Screen.PETATE) { launcher.back() }
    AnimatedContent(launcher.screen, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "screen") { current ->
        when (current) {
            Screen.CAMPAMENTO -> CampamentoScreen(
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
                widgetIds = launcher.board.ids,
                widgetHeightDp = widgetViews::heightDp,
                widgetView = widgetViews::view,
                onCampMenu = launcher::openCampMenu,
            )
            Screen.PETATE -> PetateScreen(
                apps = launcher.apps,
                hidden = launcher.home.hidden.toSet(),
                focusSearch = launcher.focusSearch,
                onOpenApp = launcher::openFromPetate,
                onAppMenu = launcher::openMenu,
                recent = launcher.visibleRecent().mapNotNull { pkg -> launcher.apps.find { it.packageName == pkg } },
            )
        }
    }
    if (launcher.campMenu) {
        CampMenuSheet(
            placed = launcher.placedWidgets().map { PlacedWidget(it.id, it.label) },
            dotsAllowed = actions.dotsAllowed(),
            onAdd = launcher::showPicker,
            onRemove = launcher::removeWidget,
            onAllowDots = launcher::allowDots,
            onDismiss = launcher::dismissCampMenu,
        )
    }
    launcher.picker?.let { options ->
        WidgetPickerSheet(options, onPick = launcher::addWidget, onDismiss = launcher::dismissPicker)
    }
    launcher.menu?.let { m ->
        AppMenuSheet(
            app = m.app,
            entries = m.entries,
            canReadShortcuts = m.canReadShortcuts,
            onDismiss = launcher::dismissMenu,
            onPick = launcher::pick,
        )
    }
}
