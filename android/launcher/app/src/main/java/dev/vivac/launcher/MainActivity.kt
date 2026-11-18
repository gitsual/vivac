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
import dev.vivac.launcher.apps.GestureContract
import android.graphics.RectF
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
    private val drag = dev.vivac.launcher.campamento.DragBoard()
    private lateinit var source: AndroidAppSource
    private lateinit var actions: AppActions
    private lateinit var widgets: Widgets
    private lateinit var launcher: Launcher
    private var watcher: LauncherApps.Callback? = null

    private var facts by mutableStateOf<PhoneFacts?>(null)
    /** Mobile signal, Wi-Fi and Tailscale, followed while vivac is in front. */
    private val status by lazy { dev.vivac.launcher.apps.AndroidStatus(this) }
    private var stamp by mutableStateOf("")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val bars = SystemBarStyle.dark(Ink.surface.toArgb())
        enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
        source = AndroidAppSource(this)
        actions = AppActions(this)
        widgets = Widgets(this)
        launcher = Launcher(source, PrefsStore(getSharedPreferences("home", MODE_PRIVATE)), actions, widgets, savedInstanceState?.getInt(KEY_PENDING, -1) ?: -1, dev.vivac.launcher.apps.AndroidDirectory(this), dev.vivac.launcher.apps.AndroidNotices)
        // Started by the system's pull-down on the home screen: open straight on vivac's shade.
        if (savedInstanceState == null && intent?.action == ACTION_OPEN_AVISOS) launcher.openAvisos()
        watcher = source.watch { refresh() }
        refresh()
        val views = object : WidgetViews {
            override fun heightDp(id: Int, rows: Int) = widgets.heightDp(id, rows)
            override fun view(context: Context, id: Int, widthDp: Float, rows: Int, grip: dev.vivac.launcher.widgets.Grip) =
                widgets.view(context, id, widthDp, rows, grip)
        }

        val icons = dev.vivac.launcher.apps.AppIcons(this)
        setContent {
            val dots by Dots.live.collectAsState()
            val counts by Dots.liveCounts.collectAsState()
            CompositionLocalProvider(LocalDots provides dots, dev.vivac.launcher.apps.LocalCounts provides counts, dev.vivac.launcher.apps.LocalAppIcons provides icons) {
                val connections by status.live.collectAsState()
                facts?.let { LauncherApp(launcher, stamp, it, actions, views, drag, connections) }
            }
        }
    }

    @Deprecated("The widget host API still answers through onActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION") super.onActivityResult(requestCode, resultCode, data)
        val uri = data?.data
        if (resultCode == RESULT_OK && uri != null) {
            when (requestCode) {
                AppActions.REQ_BACKUP -> return saveCopy(uri)
                AppActions.REQ_RESTORE -> return readCopy(uri)
            }
        }
        val step = when (requestCode) {
            Widgets.REQ_BIND -> WidgetStep.BIND
            Widgets.REQ_CONFIGURE -> WidgetStep.CONFIGURE
            else -> return
        }
        launcher.onWidgetResult(step, resultCode == RESULT_OK)
    }

    private fun saveCopy(uri: android.net.Uri) {
        val ok = runCatching { contentResolver.openOutputStream(uri, "wt")!!.use { it.write(launcher.exportLayout().toByteArray()) } }
            .onFailure { android.util.Log.w("vivac", "copy not saved", it) }.isSuccess
        actions.say(if (ok) "Copia del campamento guardada." else "No se pudo guardar la copia.")
    }

    private fun readCopy(uri: android.net.Uri) {
        runCatching { contentResolver.openInputStream(uri)!!.use { it.readBytes().decodeToString() } }
            .onSuccess(launcher::restoreLayout)
            .onFailure { actions.say("No se pudo leer ese archivo.") }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt(KEY_PENDING, launcher.pendingWidget)
    }

    /** Android's once-a-minute tick (and clock or time zone changes) refresh the stamp and the facts. */
    private val clock = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = tick()
    }

    /** A work profile paused or resumed, the private space locked or unlocked: its apps come and go. */
    private val profilesChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = launcher.refresh()
    }

    override fun onStart() {
        super.onStart()
        widgets.startListening()
        val profiles = IntentFilter().apply {
            addAction(Intent.ACTION_MANAGED_PROFILE_AVAILABLE)
            addAction(Intent.ACTION_MANAGED_PROFILE_UNAVAILABLE)
            // Intent.ACTION_PROFILE_(UN)AVAILABLE, Android 15 (the private space); vivac compiles against 14.
            addAction("android.intent.action.PROFILE_AVAILABLE")
            addAction("android.intent.action.PROFILE_UNAVAILABLE")
        }
        registerReceiver(profilesChanged, profiles)
        val times = IntentFilter().apply {
            addAction(Intent.ACTION_TIME_TICK)
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
        }
        registerReceiver(clock, times)
        status.start()
        tick()
    }

    override fun onStop() {
        status.stop()
        unregisterReceiver(clock)
        unregisterReceiver(profilesChanged)
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
        if (intent.action == ACTION_OPEN_AVISOS) return launcher.openAvisos()
        if (intent.hasCategory(Intent.CATEGORY_HOME)) {
            launcher.onHomePressed()
            // Swiping home from an app: tell Android where its icon is, so the window closes into it.
            GestureContract.from(intent)?.let { contract ->
                val tile = drag.tileOf(contract.packageName)
                contract.reply(tile?.let { RectF(it.left, it.top, it.right, it.bottom) } ?: RectF())
            }
        }
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

    companion object {
        /** What vivac-os's SystemUI sends, through the AvisosEntry alias, when you pull down on the home screen. */
        const val ACTION_OPEN_AVISOS = "dev.vivac.launcher.action.OPEN_AVISOS"
    }
}
