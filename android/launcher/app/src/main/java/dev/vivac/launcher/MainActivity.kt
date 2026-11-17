package dev.vivac.launcher

import android.content.Intent
import android.content.pm.LauncherApps
import android.os.Bundle
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
import dev.vivac.launcher.campamento.PhoneFacts
import dev.vivac.launcher.campamento.Stamp
import dev.vivac.launcher.petate.PetateScreen
import dev.vivac.launcher.theme.Ink
import kotlinx.coroutines.delay
import java.time.LocalDateTime

private enum class Screen { CAMPAMENTO, PETATE }

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val bars = SystemBarStyle.dark(Ink.surface.toArgb())
        enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
        source = AndroidAppSource(this)
        actions = AppActions(this)
        icons = AppIcons(this)
        watcher = source.watch { changed -> icons.forget(changed); apps = source.installed() }
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
                            onOpenApp = { actions.open(it) },
                            onAppInfo = { actions.info(it) },
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
                        onAppInfo = { actions.info(it) },
                    )
                }
            }
            }
        }
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
        facts = PhoneFacts.read(this)
        stamp = Stamp.format(LocalDateTime.now())
    }
}
