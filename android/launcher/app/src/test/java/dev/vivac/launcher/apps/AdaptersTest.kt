package dev.vivac.launcher.apps

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.pm.LauncherApps
import android.content.pm.ShortcutInfo
import android.os.Looper
import android.os.Process
import android.provider.Settings
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.petate.AppShortcut
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowToast

@RunWith(AndroidJUnit4::class)
class AdaptersTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val launcherApps = shadowOf(app.getSystemService(LauncherApps::class.java))
    private val me = Process.myUserHandle()

    private fun nextIntent(): Intent? = shadowOf(app).nextStartedActivity

    @Test
    fun `installed apps come from LauncherApps, once per package, without vivac itself`() {
        launcherApps.addActivity(me, Robo.activity(app, "Termux", "com.termux"))
        launcherApps.addActivity(me, Robo.activity(app, "Termux", "com.termux"))
        launcherApps.addActivity(me, Robo.activity(app, "Ajustes", "com.android.settings", system = true))
        launcherApps.addActivity(me, Robo.activity(app, "vivac", app.packageName))
        // The shadow does not promise an order, and the Petate sorts on its own: compare as a set, sizes too.
        val installed = AndroidAppSource(app).installed()
        assertEquals(2, installed.size)
        assertEquals(
            setOf(InstalledApp("Termux", "com.termux", false), InstalledApp("Ajustes", "com.android.settings", true)),
            installed.toSet(),
        )
    }

    @Test
    fun `watching reports added and removed packages until unwatched`() {
        val source = AndroidAppSource(app)
        val seen = mutableListOf<String>()
        val callback = source.watch { seen += it }
        launcherApps.notifyPackageAdded("a.b")
        launcherApps.notifyPackageRemoved("c.d")
        shadowOf(Looper.getMainLooper()).idle()
        callback.onPackageChanged("e.f", me)
        callback.onPackagesAvailable(arrayOf("g.h"), me, false)
        callback.onPackagesUnavailable(arrayOf("i.j"), me, false)
        source.unwatch(callback)
        launcherApps.notifyPackageAdded("late")
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf("a.b", "c.d", "e.f", "g.h", "i.j"), seen)
    }

    @Test
    fun `shortcuts are read only as the default home and started through LauncherApps`() {
        val actions = AppActions(app)
        launcherApps.setHasShortcutHostPermission(false)
        assertFalse(actions.canReadShortcuts())
        assertEquals(emptyList<AppShortcut>(), actions.shortcuts("com.termux"))
        launcherApps.setHasShortcutHostPermission(true)
        assertTrue(actions.canReadShortcuts())
        // Robolectric cannot answer manifest-shortcut queries; a failing query is an empty menu, not a crash.
        assertEquals(emptyList<AppShortcut>(), actions.shortcuts("com.termux"))
        actions.openShortcut(app.packageName, "a")
    }

    @Test
    fun `shortcuts are ordered by rank, blank labels kept for the menu to judge`() {
        fun shortcut(id: String, label: String?, rank: Int) = ShortcutInfo.Builder(app, id)
            .apply { if (label != null) setShortLabel(label) else setShortLabel(" ") }
            .setRank(rank).setIntent(Intent(Intent.ACTION_VIEW)).build()
        assertEquals(
            listOf(AppShortcut("a", "Primero"), AppShortcut("c", " "), AppShortcut("b", "Segundo")),
            AppActions.ordered(listOf(shortcut("b", "Segundo", 2), shortcut("a", "Primero", 0), shortcut("c", null, 1))),
        )
    }

    @Test
    fun `opening an app starts its launch intent, and an app without one is ignored`() {
        shadowOf(app.packageManager).addActivityIfNotPresent(ComponentName("com.termux", "com.termux.Main"))
        shadowOf(app.packageManager).addIntentFilterForActivity(
            ComponentName("com.termux", "com.termux.Main"),
            android.content.IntentFilter(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_LAUNCHER) },
        )
        val actions = AppActions(app)
        actions.open("com.termux")
        assertEquals(ComponentName("com.termux", "com.termux.Main"), nextIntent()?.component)
        actions.open("not.installed")
        assertNull(nextIntent())
    }

    @Test
    fun `system pages are opened as new tasks`() {
        val actions = AppActions(app)
        actions.info("com.termux")
        nextIntent()!!.let {
            assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, it.action)
            assertEquals("package:com.termux", it.dataString)
            assertTrue(it.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        }
        actions.uninstall("com.termux")
        nextIntent()!!.let { assertEquals(Intent.ACTION_DELETE, it.action); assertEquals("package:com.termux", it.dataString) }
        actions.systemSettings()
        assertEquals(Settings.ACTION_SETTINGS, nextIntent()?.action)
        actions.securityUpdates()
        assertEquals(Settings.ACTION_DEVICE_INFO_SETTINGS, nextIntent()?.action)
        actions.notificationAccess()
        nextIntent()!!.let {
            assertEquals(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS, it.action)
            assertEquals(ComponentName(app, DotsListener::class.java).flattenToString(), it.getStringExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME))
        }
    }

    @Test
    fun `when the detail page is missing, notification access falls back to the list`() {
        shadowOf(app).checkActivities(true)
        shadowOf(app.packageManager).addActivityIfNotPresent(ComponentName("com.android.settings", "Listeners"))
        shadowOf(app.packageManager).addIntentFilterForActivity(
            ComponentName("com.android.settings", "Listeners"),
            android.content.IntentFilter(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply { addCategory(Intent.CATEGORY_DEFAULT) },
        )
        AppActions(app).notificationAccess()
        assertEquals(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS, nextIntent()?.action)
        // And nothing at all to open is not a crash.
        AppActions(app).uninstall("x")
        assertNull(nextIntent())
    }

    @Test
    fun `pulling the shade never crashes, saying shows a toast, dots follow the system list`() {
        val actions = AppActions(app)
        actions.showNotifications()
        actions.say("hola")
        assertEquals("hola", ShadowToast.getTextOfLatestToast())
        assertFalse(actions.dotsAllowed())
        val me = ComponentName(app, DotsListener::class.java).flattenToString()
        Settings.Secure.putString(app.contentResolver, "enabled_notification_listeners", "other/x:$me")
        assertTrue(actions.dotsAllowed())
    }

    @Test
    fun `prefs store reads back what it wrote`() {
        val store = PrefsStore(app.getSharedPreferences("t", 0))
        assertNull(store.get("dock"))
        store.put(mapOf("dock" to "a,b", "pinned" to ""))
        assertEquals("a,b", store.get("dock"))
        assertEquals("", store.get("pinned"))
    }
}
