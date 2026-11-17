package dev.vivac.launcher

import android.content.Intent
import android.content.pm.LauncherApps
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.toArgb
import dev.vivac.launcher.apps.AndroidAppSource
import dev.vivac.launcher.apps.AppActions
import dev.vivac.launcher.apps.AppIcons
import dev.vivac.launcher.apps.LocalAppIcons
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.campamento.CampamentoScreen
import dev.vivac.launcher.campamento.Dock
import dev.vivac.launcher.campamento.DockSlot
import dev.vivac.launcher.campamento.Home
import dev.vivac.launcher.campamento.HomeChange
import dev.vivac.launcher.campamento.PhoneFacts
import dev.vivac.launcher.campamento.Stamp
import dev.vivac.launcher.petate.AppMenu
import dev.vivac.launcher.petate.AppMenuSheet
import dev.vivac.launcher.petate.MenuEntry
import dev.vivac.launcher.petate.PetateScreen
import dev.vivac.launcher.theme.Ink
import kotlinx.coroutines.delay
import java.time.LocalDateTime

private enum class Screen { CAMPAMENTO, PETATE }

private const val KEY_DOCK = "dock"
private const val KEY_PINNED = "pinned"

private data class OpenMenu(val app: InstalledApp, val entries: List<MenuEntry>, val canReadShortcuts: Boolean)

class MainActivity : ComponentActivity() {
    private lateinit var source: AndroidAppSource
    private lateinit var actions: AppActions
    private lateinit var icons: AppIcons
    private var watcher: LauncherApps.Callback? = null

    private var apps by mutableStateOf(emptyList<InstalledApp>())
    private var facts by mutableStateOf<PhoneFacts?>(null)
    private var stamp by mutableStateOf("")
    private var screen by mutableStateOf(Screen.CAMPAMENTO)
    private var focusSearch by mutableStateOf(false)
    private var menu by mutableStateOf<OpenMenu?>(null)
    private var home by mutableStateOf(Home())
    private val prefs by lazy { getSharedPreferences("home", MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val bars = SystemBarStyle.dark(Ink.surface.toArgb())
        enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
        source = AndroidAppSource(this)
        actions = AppActions(this)
        icons = AppIcons(this)
        watcher = source.watch { changed -> icons.forget(changed); refresh() }
        home = Home.decode(prefs.getString(KEY_DOCK, null), prefs.getString(KEY_PINNED, null))
        refresh()

        setContent {
            LaunchedEffect(Unit) {
                while (true) {
                    stamp = Stamp.format(LocalDateTime.now())
                    facts = PhoneFacts.read(this@MainActivity)
                    delay(60_000L - System.currentTimeMillis() % 60_000L)
                }
            }
            CompositionLocalProvider(LocalAppIcons provides icons) {
            BackHandler(enabled = screen == Screen.PETATE) { screen = Screen.CAMPAMENTO }
            AnimatedContent(screen, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "screen") { current ->
                when (current) {
                    Screen.CAMPAMENTO -> facts?.let { f ->
                        CampamentoScreen(
                            stamp = stamp,
                            facts = f,
                            apps = apps,
                            home = home,
                            onOpenApp = { actions.open(it) },
                            onAppMenu = ::openMenu,
                            onOpenPetate = { search -> focusSearch = search; screen = Screen.PETATE },
                            onOpenSettings = { actions.systemSettings() },
                            onOpenAbout = { actions.securityUpdates() },
                            onShowNotifications = { actions.showNotifications() },
                        )
                    }
                    Screen.PETATE -> PetateScreen(
                        apps = apps,
                        focusSearch = focusSearch,
                        onOpenApp = { actions.open(it); screen = Screen.CAMPAMENTO },
                        onAppMenu = ::openMenu,
                    )
                }
            }
            menu?.let { m ->
                AppMenuSheet(
                    app = m.app,
                    entries = m.entries,
                    canReadShortcuts = m.canReadShortcuts,
                    onDismiss = { menu = null },
                    onPick = { entry ->
                        menu = null
                        when (entry) {
                            is MenuEntry.Shortcut -> actions.openShortcut(m.app.packageName, entry.shortcut.id)
                            is MenuEntry.Dock -> apply(home.copy(dock = shownDock()).toggleDock(m.app.packageName))
                            is MenuEntry.Pin -> apply(home.togglePin(m.app.packageName))
                            MenuEntry.Info -> actions.info(m.app.packageName)
                            MenuEntry.Uninstall -> actions.uninstall(m.app.packageName)
                        }
                    },
                )
            }
            }
        }
    }

    private fun openMenu(packageName: String) {
        val app = apps.find { it.packageName == packageName } ?: return
        val shortcuts = actions.shortcuts(packageName)
        val entries = AppMenu.build(shortcuts, app.isSystem, inDock = packageName in shownDock(), pinned = packageName in home.pinned)
        menu = OpenMenu(app, entries, actions.canReadShortcuts())
    }

    /** The dock as it is on screen: your choice, or the default favourites until you edit it. */
    private fun shownDock(): List<String> =
        Dock.pick(apps.map { it.packageName }.toSet(), home.dock).filterIsInstance<DockSlot.App>().map { it.packageName }

    private fun apply(change: HomeChange) {
        val next = change.home ?: return Toast.makeText(this, change.refusal, Toast.LENGTH_LONG).show()
        home = next
        prefs.edit().putString(KEY_DOCK, next.encodeDock()).putString(KEY_PINNED, next.encodePinned()).apply()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    /** Pressing Home while vivac is in front brings you back to the Campamento. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) screen = Screen.CAMPAMENTO
    }

    override fun onDestroy() {
        watcher?.let { source.unwatch(it) }
        super.onDestroy()
    }

    private fun refresh() {
        apps = source.installed()
        // An empty list means Android is not ready (e.g. right after boot), not that every app is gone:
        // never let that wipe the dock and pins.
        if (apps.isNotEmpty()) {
            val kept = home.keepOnly(apps.map { it.packageName }.toSet())
            if (kept != home) apply(HomeChange(kept))
        }
        facts = PhoneFacts.read(this)
        stamp = Stamp.format(LocalDateTime.now())
    }
}
