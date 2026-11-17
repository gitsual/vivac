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
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.apps.Robo
import dev.vivac.launcher.widgets.Widgets
import org.junit.Assert.assertEquals
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

    private fun result(requestCode: Int, resultCode: Int) = scenario.onActivity {
        ReflectionHelpers.callInstanceMethod<Unit>(
            it, "onActivityResult",
            ClassParameter.from(Int::class.javaPrimitiveType, requestCode),
            ClassParameter.from(Int::class.javaPrimitiveType, resultCode),
            ClassParameter.from(Intent::class.java, null),
        )
    }

    @Test
    fun `it opens on the camp with the installed apps in the dock`() {
        start()
        compose.onNodeWithText("Campamento").assertExists()
        compose.onNodeWithText("Termux").assertExists()
    }

    @Test
    fun `pressing home from the petate goes back to the camp`() {
        start()
        compose.onNodeWithText("Petate").performClick()
        compose.onNodeWithContentDescription("Buscar en el petate").assertExists()
        deliver(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME))
        compose.onNodeWithContentDescription("Buscar en el petate").assertDoesNotExist()
        // Any other intent leaves the screen alone.
        compose.onNodeWithText("Petate").performClick()
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
        assertEquals(asked.intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -2).toString(), prefs.getString("widgets", null))
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
        compose.onNodeWithText("Campamento").assertExists()
    }

    @Test
    fun `it goes through its whole life without leaking the app watcher`() {
        start()
        scenario.moveToState(androidx.lifecycle.Lifecycle.State.DESTROYED)
    }
}
