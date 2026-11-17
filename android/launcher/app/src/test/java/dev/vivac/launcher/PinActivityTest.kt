package dev.vivac.launcher

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.LauncherApps
import android.content.pm.ShortcutInfo
import android.os.Bundle
import android.os.Process
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.campamento.Pinned
import dev.vivac.launcher.campamento.WidgetBoard
import dev.vivac.launcher.widgets.Widgets
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.util.ReflectionHelpers
import java.lang.reflect.Proxy

@RunWith(AndroidJUnit4::class)
class PinActivityTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val app = ApplicationProvider.getApplicationContext<android.app.Application>()
    private val prefs get() = app.getSharedPreferences("home", 0)
    private val board get() = WidgetBoard.decode(prefs.getString("widgets", null))
    private val accepted = mutableListOf<Int>()
    private var scenario: ActivityScenario<PinActivity>? = null

    @After
    fun close() { scenario?.close() }

    private val clock = AppWidgetProviderInfo().apply {
        provider = ComponentName("a.clock", "a.clock.Widget")
        ReflectionHelpers.setField(this, "providerInfo", ActivityInfo().apply {
            packageName = "a.clock"; name = "a.clock.Widget"; nonLocalizedLabel = "Reloj"
            applicationInfo = ApplicationInfo().apply { packageName = "a.clock" }
        })
    }

    /** Android's request, as the system would hand it over; it cannot be built through the public API. */
    private fun request(type: Int, shortcut: ShortcutInfo? = null, widget: AppWidgetProviderInfo? = null, valid: Boolean = true): LauncherApps.PinItemRequest {
        val inner = Class.forName("android.content.pm.IPinItemRequest")
        val proxy = Proxy.newProxyInstance(inner.classLoader, arrayOf(inner)) { _, method, args ->
            when (method.name) {
                "isValid" -> valid
                "accept" -> { accepted += ((args?.firstOrNull() as Bundle?)?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, -1) ?: -1); true }
                "getShortcutInfo" -> shortcut
                "getAppWidgetProviderInfo" -> widget
                else -> null
            }
        }
        val ctor = LauncherApps.PinItemRequest::class.java.getDeclaredConstructor(inner, Int::class.javaPrimitiveType)
        ctor.isAccessible = true
        return ctor.newInstance(proxy, type)
    }

    private fun launch(request: LauncherApps.PinItemRequest?): ActivityScenario<PinActivity> {
        val intent = Intent(LauncherApps.ACTION_CONFIRM_PIN_SHORTCUT).setClass(app, PinActivity::class.java)
        request?.let { intent.putExtra(LauncherApps.EXTRA_PIN_ITEM_REQUEST, it) }
        return ActivityScenario.launch<PinActivity>(intent).also { scenario = it }
    }

    private fun shortcut() = ShortcutInfo.Builder(app, "chat-ana").setShortLabel("Ana").setIntent(Intent(Intent.ACTION_VIEW)).build()

    private fun finishing(s: ActivityScenario<PinActivity>): Boolean {
        if (s.state == androidx.lifecycle.Lifecycle.State.DESTROYED) return true
        var f = false
        s.onActivity { f = it.isFinishing }
        return f
    }

    @Test
    fun `a shortcut another app offers goes on a ladera when you add it`() {
        val s = launch(request(LauncherApps.PinItemRequest.REQUEST_TYPE_SHORTCUT, shortcut = shortcut()))
        compose.onNodeWithText("Ana").assertExists()
        compose.onNodeWithText("Irá a la ladera 1. Luego puedes llevarlo donde quieras.").assertExists()
        compose.onNodeWithText("Añadir").performClick()
        compose.waitForIdle()
        assertEquals(listOf(-1), accepted)
        assertEquals(listOf(Pinned(app.packageName, "chat-ana", "Ana", 1)), board.onPage(1))
        assertTrue(finishing(s))
    }

    @Test
    fun `saying not now adds nothing`() {
        val s = launch(request(LauncherApps.PinItemRequest.REQUEST_TYPE_SHORTCUT, shortcut = shortcut()))
        compose.onNodeWithText("Ahora no").performClick()
        compose.waitForIdle()
        assertEquals(emptyList<Int>(), accepted)
        assertEquals(WidgetBoard(), board)
        assertTrue(finishing(s))
    }

    @Test
    fun `without a valid request there is nothing to show`() {
        assertTrue(finishing(launch(null)))
        assertTrue(finishing(launch(request(LauncherApps.PinItemRequest.REQUEST_TYPE_SHORTCUT, shortcut = shortcut(), valid = false))))
        assertTrue(finishing(launch(request(LauncherApps.PinItemRequest.REQUEST_TYPE_APPWIDGET))))
    }

    @Test
    fun `a widget another app offers is bound and placed on a ladera`() {
        shadowOf(AppWidgetManager.getInstance(app)).setAllowedToBindAppWidgets(true)
        val s = launch(request(LauncherApps.PinItemRequest.REQUEST_TYPE_APPWIDGET, widget = clock))
        compose.onNodeWithText("Reloj").assertExists()
        compose.onNodeWithText("Añadir").performClick()
        compose.waitForIdle()
        assertEquals(1, board.ids.size)
        assertEquals(board.ids, accepted)
        assertTrue(finishing(s))
    }

    @Test
    fun `a widget waits for the bind dialog, also across a restart`() {
        shadowOf(AppWidgetManager.getInstance(app)).setAllowedToBindAppWidgets(false)
        val s = launch(request(LauncherApps.PinItemRequest.REQUEST_TYPE_APPWIDGET, widget = clock))
        compose.onNodeWithText("Añadir").performClick()
        compose.waitForIdle()
        s.onActivity { assertEquals(AppWidgetManager.ACTION_APPWIDGET_BIND, shadowOf(it).nextStartedActivity.action) }
        s.recreate()
        s.onActivity {
            @Suppress("DEPRECATION")
            ReflectionHelpers.callInstanceMethod<Unit>(it, "onActivityResult",
                ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType, 1),
                ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType, Activity.RESULT_OK),
                ReflectionHelpers.ClassParameter.from(Intent::class.java, null))
            ReflectionHelpers.callInstanceMethod<Unit>(it, "onActivityResult",
                ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType, Widgets.REQ_BIND),
                ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType, Activity.RESULT_OK),
                ReflectionHelpers.ClassParameter.from(Intent::class.java, null))
        }
        compose.waitForIdle()
        assertEquals(1, board.ids.size)
    }

    @Test
    fun `a widget whose bind is refused is let go`() {
        shadowOf(AppWidgetManager.getInstance(app)).setAllowedToBindAppWidgets(false)
        val s = launch(request(LauncherApps.PinItemRequest.REQUEST_TYPE_APPWIDGET, widget = clock))
        compose.onNodeWithText("Añadir").performClick()
        compose.waitForIdle()
        s.onActivity {
            ReflectionHelpers.callInstanceMethod<Unit>(it, "onActivityResult",
                ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType, Widgets.REQ_CONFIGURE),
                ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType, Activity.RESULT_CANCELED),
                ReflectionHelpers.ClassParameter.from(Intent::class.java, null))
        }
        compose.waitForIdle()
        assertEquals(WidgetBoard(), board)
        assertTrue(finishing(s))
    }
}
