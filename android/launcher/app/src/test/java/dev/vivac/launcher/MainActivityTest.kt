package dev.vivac.launcher

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.LauncherApps
import android.os.Process
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.swipeUp
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.apps.Robo
import dev.vivac.launcher.widgets.Widgets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter

@RunWith(AndroidJUnit4::class)
class MainActivityTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val app = ApplicationProvider.getApplicationContext<android.app.Application>()
    private val prefs get() = app.getSharedPreferences("home", 0)
    private lateinit var clock: AppWidgetProviderInfo

    @Before
    fun installApps() {
        val launcherApps = shadowOf(app.getSystemService(LauncherApps::class.java))
        launcherApps.addActivity(Process.myUserHandle(), Robo.activity(app, "Termux", "com.termux"))
        launcherApps.addActivity(Process.myUserHandle(), Robo.activity(app, "Organic Maps", "app.organicmaps"))
        clock = AppWidgetProviderInfo().apply {
            provider = ComponentName("a.clock", "a.clock.Widget")
            ReflectionHelpers.setField(this, "providerInfo", ActivityInfo().apply {
                packageName = "a.clock"; name = "a.clock.Widget"; nonLocalizedLabel = "Reloj"
                applicationInfo = ApplicationInfo().apply { packageName = "a.clock" }
            })
        }
        shadowOf(AppWidgetManager.getInstance(app)).apply {
            addInstalledProvidersForProfile(Process.myUserHandle(), clock)
            setAllowedToBindAppWidgets(false)
        }
    }

    private lateinit var scenario: ActivityScenario<MainActivity>

    @After
    fun finish() {
        if (::scenario.isInitialized) scenario.close()
    }

    /**
     * Launched through ActivityScenario, as the Compose rule expects: an activity built by hand
     * outlives the rule's bookkeeping and the next test in the class never gets idle.
     */
    private fun start(): MainActivity {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        return current()
    }

    private fun current(): MainActivity {
        lateinit var activity: MainActivity
        scenario.onActivity { activity = it }
        return activity
    }

    private fun deliver(intent: Intent) = scenario.onActivity {
        ReflectionHelpers.callInstanceMethod<Unit>(it, "onNewIntent", ClassParameter.from(Intent::class.java, intent))
    }

    private fun result(requestCode: Int, resultCode: Int, data: Intent? = null) = scenario.onActivity {
        ReflectionHelpers.callInstanceMethod<Unit>(
            it, "onActivityResult",
            ClassParameter.from(Int::class.javaPrimitiveType, requestCode),
            ClassParameter.from(Int::class.javaPrimitiveType, resultCode),
            ClassParameter.from(Intent::class.java, data),
        )
    }

    /** What Android's swipe-home handler puts in the home intent; [answers] gets what vivac replies. */
    private fun swipeHome(pkg: String, answers: MutableList<android.os.Bundle>, enabled: Boolean = true): Intent {
        val handler = android.os.Handler(android.os.Looper.getMainLooper()) { answers += it.data; true }
        val callback = android.os.Message.obtain().apply { replyTo = android.os.Messenger(handler) }
        val contract = android.os.Bundle().apply {
            putBoolean("gesture_nav_contract_enable", enabled)
            putParcelable(Intent.EXTRA_COMPONENT_NAME, ComponentName(pkg, "$pkg.Main"))
            putParcelable(Intent.EXTRA_USER, Process.myUserHandle())
            putParcelable("android.intent.extra.REMOTE_CALLBACK", callback)
        }
        return Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).putExtra("gesture_nav_contract_v1", contract)
    }

    @Test
    fun `swiping home from an app answers android with where that app's icon is`() {
        start()
        compose.waitForIdle()
        val answers = mutableListOf<android.os.Bundle>()
        deliver(swipeHome("com.termux", answers))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        @Suppress("DEPRECATION")
        val dock = answers.single().getParcelable<android.graphics.RectF>("gesture_nav_contract_icon_position")!!
        assertTrue(!dock.isEmpty)
        deliver(swipeHome("not.on.camp", answers))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        @Suppress("DEPRECATION")
        assertTrue(answers.last().getParcelable<android.graphics.RectF>("gesture_nav_contract_icon_position")!!.isEmpty)
        deliver(swipeHome("com.termux", answers, enabled = false))
        deliver(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).putExtra("gesture_nav_contract_v1", android.os.Bundle()))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(2, answers.size)
    }

    @Test
    fun `a profile locked or unlocked refreshes the apps`() {
        start()
        app.sendBroadcast(Intent("android.intent.action.PROFILE_UNAVAILABLE"))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        compose.waitForIdle()
    }

    @Test
    fun `a copy of the camp is written to the file you choose and read back from one`() {
        prefs.edit().putString("pinned", "app.organicmaps").commit()
        start()
        val resolver = shadowOf(app.contentResolver)
        val file = android.net.Uri.parse("content://docs/copia.txt")
        val written = java.io.ByteArrayOutputStream()
        resolver.registerOutputStream(file, written)
        result(dev.vivac.launcher.apps.AppActions.REQ_BACKUP, android.app.Activity.RESULT_OK, Intent().setData(file))
        val copy = written.toString()
        assertTrue(copy.contains("pinned=app.organicmaps"))
        assertEquals("Copia del campamento guardada.", org.robolectric.shadows.ShadowToast.getTextOfLatestToast())
        resolver.registerInputStream(file, copy.replace("pinned=app.organicmaps", "pinned=com.termux").byteInputStream())
        result(dev.vivac.launcher.apps.AppActions.REQ_RESTORE, android.app.Activity.RESULT_OK, Intent().setData(file))
        assertEquals("com.termux", prefs.getString("pinned", null))
        val broken = android.net.Uri.parse("content://docs/rota.txt")
        resolver.registerInputStreamSupplier(broken) { throw java.io.IOException("gone") }
        result(dev.vivac.launcher.apps.AppActions.REQ_RESTORE, android.app.Activity.RESULT_OK, Intent().setData(broken))
        assertEquals("No se pudo leer ese archivo.", org.robolectric.shadows.ShadowToast.getTextOfLatestToast())
        resolver.registerOutputStream(broken, object : java.io.OutputStream() { override fun write(b: Int) = throw java.io.IOException("full") })
        result(dev.vivac.launcher.apps.AppActions.REQ_BACKUP, android.app.Activity.RESULT_OK, Intent().setData(broken))
        assertEquals("No se pudo guardar la copia.", org.robolectric.shadows.ShadowToast.getTextOfLatestToast())
        result(dev.vivac.launcher.apps.AppActions.REQ_BACKUP, android.app.Activity.RESULT_CANCELED, null)
    }

    @Test
    fun `it opens on the camp with the installed apps in the dock`() {
        start()
        compose.onNodeWithText("CAMPAMENTO").assertExists()
        compose.onNodeWithText("Termux").assertExists()
    }

    @Test
    fun `pressing home from the petate goes back to the camp`() {
        start()
        compose.onRoot().performTouchInput { swipeUp() }
        compose.onNodeWithContentDescription("Buscar en el petate").assertExists()
        deliver(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME))
        compose.onNodeWithContentDescription("Buscar en el petate").assertDoesNotExist()
        // Any other intent leaves the screen alone.
        compose.onRoot().performTouchInput { swipeUp() }
        deliver(Intent(Intent.ACTION_VIEW))
        compose.onNodeWithContentDescription("Buscar en el petate").assertExists()
    }

    @Test
    fun `a widget waits for the bind dialog and is placed when it is accepted`() {
        val activity = start()
        compose.onNodeWithText("LA CORDADA").performTouchInput { longClick() }
        compose.onNodeWithText("Añadir widget").performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithText("Reloj").performSemanticsAction(SemanticsActions.OnClick)
        val asked = shadowOf(activity).nextStartedActivityForResult
        assertEquals(Widgets.REQ_BIND, asked.requestCode)
        // The id survives the activity being recreated while the dialog is open.
        scenario.recreate()
        result(Widgets.REQ_BIND, Activity.RESULT_OK)
        assertEquals("${asked.intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -2)}:0:0", prefs.getString("widgets", null))
    }

    @Test
    fun `a widget with a settings screen is placed once it is configured, then drawn on the camp`() {
        clock.configure = ComponentName("a.clock", "a.clock.Setup")
        clock.minHeight = 110
        shadowOf(AppWidgetManager.getInstance(app)).apply {
            // The shadow looks a bound widget's info up in this list, not in the per-profile one.
            addInstalledProvider(clock)
            setAllowedToBindAppWidgets(true)
        }
        start()
        compose.onNodeWithText("LA CORDADA").performTouchInput { longClick() }
        compose.onNodeWithText("Añadir widget").performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithText("Reloj").performSemanticsAction(SemanticsActions.OnClick)
        // Robolectric does not record the settings screen (Android opens it through an IntentSender),
        // so the check is the effect: nothing is placed until that screen answers OK.
        assertEquals(null, prefs.getString("widgets", null))
        result(Widgets.REQ_CONFIGURE, Activity.RESULT_OK)
        assertEquals(1, prefs.getString("widgets", null).orEmpty().split(",").filter { it.isNotBlank() }.size)
        compose.onNodeWithText("LA CORDADA").assertExists()
    }

    @Test
    fun `results for anything else are ignored`() {
        start()
        result(42, Activity.RESULT_OK)
        assertEquals(null, prefs.getString("widgets", null))
    }

    @Test
    fun `the stamp follows Android's minute tick`() {
        start()
        app.sendBroadcast(Intent(Intent.ACTION_TIME_TICK))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        compose.onNodeWithText("CAMPAMENTO").assertExists()
    }

    @Test
    fun `it goes through its whole life without leaking the app watcher`() {
        start()
        scenario.moveToState(androidx.lifecycle.Lifecycle.State.DESTROYED)
    }

    private fun allowNotices(on: Boolean) {
        val app = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.app.Application>()
        val me = android.content.ComponentName(app, dev.vivac.launcher.apps.DotsListener::class.java).flattenToString()
        android.provider.Settings.Secure.putString(app.contentResolver, "enabled_notification_listeners", if (on) me else "")
    }

    @Test
    fun `the system's pull-down on the home screen opens vivac's shade, or Android's without notification access`() {
        allowNotices(false)
        start()
        deliver(Intent(MainActivity.ACTION_OPEN_AVISOS))
        compose.onNodeWithText("VIVAC · AVISOS").assertDoesNotExist()
        allowNotices(true)
        deliver(Intent(MainActivity.ACTION_OPEN_AVISOS))
        compose.onNodeWithText("VIVAC · AVISOS").assertExists()
    }

    @Test
    fun `started cold by the system's pull-down, vivac opens straight on its shade`() {
        allowNotices(true)
        val intent = Intent(androidx.test.core.app.ApplicationProvider.getApplicationContext(), MainActivity::class.java).setAction(MainActivity.ACTION_OPEN_AVISOS)
        scenario = ActivityScenario.launch(intent)
        compose.onNodeWithText("VIVAC · AVISOS").assertExists()
    }

    @Test
    fun `only the system can open vivac's shade from outside, through its entry`() {
        val app = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.app.Application>()
        val entry = app.packageManager.getActivityInfo(android.content.ComponentName(app, "dev.vivac.launcher.AvisosEntry"), 0)
        assertEquals("android.permission.STATUS_BAR_SERVICE", entry.permission)
        assertEquals(MainActivity::class.java.name, entry.targetActivity)
    }
}
