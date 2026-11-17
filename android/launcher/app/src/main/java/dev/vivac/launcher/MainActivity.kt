package dev.vivac.launcher

import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.content.Intent
import android.content.pm.LauncherApps
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.toArgb
import dev.vivac.launcher.apps.AndroidAppSource
import dev.vivac.launcher.apps.AppActions
import dev.vivac.launcher.apps.Dots
import dev.vivac.launcher.apps.LocalDots
import dev.vivac.launcher.apps.PrefsStore
import dev.vivac.launcher.campamento.PhoneFacts
import dev.vivac.launcher.campamento.Stamp
import dev.vivac.launcher.core.Launcher
import dev.vivac.launcher.core.LauncherApp
import dev.vivac.launcher.core.WidgetStep
import dev.vivac.launcher.core.WidgetViews
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.widgets.Widgets
import java.time.LocalDateTime

private const val KEY_PENDING = "pendingWidget"

/** Wiring only: Android adapters in, [Launcher] decides, [LauncherApp] draws. */
class MainActivity : ComponentActivity() {
    private lateinit var source: AndroidAppSource
    private lateinit var actions: AppActions
    private lateinit var widgets: Widgets
    private lateinit var launcher: Launcher
    private var watcher: LauncherApps.Callback? = null

    private var facts by mutableStateOf<PhoneFacts?>(null)
    private var stamp by mutableStateOf("")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val bars = SystemBarStyle.dark(Ink.surface.toArgb())
        enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
        source = AndroidAppSource(this)
        actions = AppActions(this)
        widgets = Widgets(this)
        launcher = Launcher(source, PrefsStore(getSharedPreferences("home", MODE_PRIVATE)), actions, widgets, savedInstanceState?.getInt(KEY_PENDING, -1) ?: -1)
        watcher = source.watch { refresh() }
        refresh()
        val views = object : WidgetViews {
            override fun heightDp(id: Int, rows: Int) = widgets.heightDp(id, rows)
            override fun view(context: Context, id: Int, widthDp: Float, rows: Int, grip: dev.vivac.launcher.widgets.Grip) =
                widgets.view(context, id, widthDp, rows, grip)
        }

        setContent {
            val dots by Dots.live.collectAsState()
            CompositionLocalProvider(LocalDots provides dots) {
                facts?.let { LauncherApp(launcher, stamp, it, actions, views) }
            }
        }
    }

    @Deprecated("The widget host API still answers through onActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION") super.onActivityResult(requestCode, resultCode, data)
        val step = when (requestCode) {
            Widgets.REQ_BIND -> WidgetStep.BIND
            Widgets.REQ_CONFIGURE -> WidgetStep.CONFIGURE
            else -> return
        }
        launcher.onWidgetResult(step, resultCode == RESULT_OK)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt(KEY_PENDING, launcher.pendingWidget)
    }

    /** Android's once-a-minute tick (and clock or time zone changes) refresh the stamp and the facts. */
    private val clock = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = tick()
    }

    override fun onStart() {
        super.onStart()
        widgets.startListening()
        val times = IntentFilter().apply {
            addAction(Intent.ACTION_TIME_TICK)
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
        }
        registerReceiver(clock, times)
        tick()
    }

    override fun onStop() {
        unregisterReceiver(clock)
        widgets.stopListening()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    /** Pressing Home while vivac is in front brings you back to the Campamento. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) launcher.onHomePressed()
    }

    override fun onDestroy() {
        watcher?.let { source.unwatch(it) }
        super.onDestroy()
    }

    private fun refresh() {
        launcher.refresh()
        tick()
    }

    private fun tick() {
        stamp = Stamp.format(LocalDateTime.now())
        facts = PhoneFacts.read(this)
    }
}
