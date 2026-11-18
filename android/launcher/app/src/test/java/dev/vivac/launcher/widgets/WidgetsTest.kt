package dev.vivac.launcher.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.os.Process
import androidx.activity.ComponentActivity
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.util.ReflectionHelpers
import org.robolectric.shadows.ShadowLooper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.ViewConfiguration
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class WidgetsTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val manager = shadowOf(AppWidgetManager.getInstance(activity))
    private val density = activity.resources.displayMetrics.density

    private fun provider(pkg: String, label: String, rows: Int = 2, configure: Boolean = false) = AppWidgetProviderInfo().apply {
        provider = ComponentName(pkg, "$pkg.Widget")
        // A hidden field: loadLabel reads the label from it.
        ReflectionHelpers.setField(this, "providerInfo", ActivityInfo().apply {
            packageName = pkg
            name = "$pkg.Widget"
            nonLocalizedLabel = label
            applicationInfo = ApplicationInfo().apply { packageName = pkg; nonLocalizedLabel = label }
        })
        minHeight = (40 * density).toInt()
        targetCellWidth = 4
        targetCellHeight = rows
        if (configure) this.configure = ComponentName(pkg, "$pkg.Setup")
    }

    @Test
    fun `options list every provider, sorted the Spanish way, with its size`() {
        manager.addInstalledProvidersForProfile(Process.myUserHandle(), provider("z.music", "Música"))
        manager.addInstalledProvidersForProfile(Process.myUserHandle(), provider("a.clock", "Reloj", rows = 1))
        val options = Widgets(activity).options()
        assertEquals(listOf("a.clock/a.clock.Widget", "z.music/z.music.Widget"), options.map { it.key })
        assertEquals("4 × 1", options[0].cells)
        assertEquals("Reloj", options[0].label)
        assertEquals("a.clock", options[0].appLabel)
    }

    @Test
    fun `binding asks Android, and without permission opens the bind dialog for a result`() {
        val widgets = Widgets(activity)
        val option = WidgetOption("a.clock/a.clock.Widget", "Reloj", "Reloj", "a.clock", "4 × 2")
        manager.setAllowedToBindAppWidgets(true)
        assertTrue(widgets.bindIfAllowed(widgets.allocate(), option))
        manager.setAllowedToBindAppWidgets(false)
        val id = widgets.allocate()
        assertFalse(widgets.bindIfAllowed(id, option))
        widgets.requestBind(id, option)
        val asked = shadowOf(activity).nextStartedActivityForResult
        assertEquals(Widgets.REQ_BIND, asked.requestCode)
        assertEquals(AppWidgetManager.ACTION_APPWIDGET_BIND, asked.intent.action)
        assertEquals(id, asked.intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1))
    }

    @Test
    fun `a placed widget has a label, a height in rows, a live view, and can be removed`() {
        val widgets = Widgets(activity)
        widgets.startListening()
        manager.addBoundWidget(7, provider("a.clock", "Reloj", rows = 2, configure = true))
        assertTrue(widgets.exists(7))
        assertTrue(widgets.needsConfiguring(7))
        assertEquals("Reloj", widgets.label(7))
        assertEquals(180, widgets.heightDp(7))
        assertEquals(2, widgets.defaultRows(7))
        assertEquals(270, widgets.heightDp(7, rows = 3))
        assertNotNull(widgets.view(activity, 7, 360f, rows = 3, Recorder()))
        widgets.requestConfigure(7)
        widgets.delete(7)
        widgets.stopListening()
    }

    @Test
    fun `an unknown widget id is not there`() {
        val widgets = Widgets(activity)
        assertFalse(widgets.exists(99))
        assertFalse(widgets.needsConfiguring(99))
        assertEquals("widget", widgets.label(99))
        assertEquals(72, widgets.heightDp(99))
        assertNull(widgets.view(activity, 99, 360f, rows = 0, Recorder()))
    }

    private fun touch(view: android.view.View, action: Int, x: Float = 20f, y: Float = 20f) =
        view.dispatchTouchEvent(MotionEvent.obtain(0, SystemClock.uptimeMillis(), action, x, y, 0))

    private class Recorder : Grip {
        val calls = mutableListOf<String>()
        var look: android.graphics.Bitmap? = null
        override fun lift(x: Float, y: Float, look: android.graphics.Bitmap?) { calls += "lift:${x.toInt()},${y.toInt()}"; this.look = look }
        override fun move(dx: Float, dy: Float) { calls += "move:${dx.toInt()},${dy.toInt()}" }
        override fun land(moved: Boolean) { calls += "land:$moved" }
        override fun cancel() { calls += "cancel" }
    }

    private fun placedView(grip: Grip): android.view.View {
        manager.addBoundWidget(7, provider("a.clock", "Reloj"))
        return Widgets(activity).view(activity, 7, 360f, rows = 0, grip)!!.apply { layout(0, 0, 400, 200) }
    }

    private fun hold() = ShadowLooper.idleMainLooper(ViewConfiguration.getLongPressTimeout() + 50L, TimeUnit.MILLISECONDS)

    @Test
    fun `holding a finger still on a widget and letting go opens vivac's card for it`() {
        val grip = Recorder()
        val view = placedView(grip)
        touch(view, MotionEvent.ACTION_DOWN)
        hold()
        assertEquals(listOf("lift:20,20"), grip.calls)
        // A picture of the widget as it was, to carry under the finger.
        assertEquals(400, grip.look?.width)
        // The rest of that gesture is vivac's, not the widget's.
        assertTrue(touch(view, MotionEvent.ACTION_UP))
        assertEquals(listOf("lift:20,20", "land:false"), grip.calls)
    }

    @Test
    fun `holding a widget and moving carries it, and the finger's path is passed on`() {
        val grip = Recorder()
        val view = placedView(grip)
        touch(view, MotionEvent.ACTION_DOWN)
        hold()
        assertTrue(touch(view, MotionEvent.ACTION_MOVE, y = 120f))
        touch(view, MotionEvent.ACTION_MOVE, x = 60f, y = 120f)
        touch(view, MotionEvent.ACTION_UP, x = 60f, y = 120f)
        assertEquals(listOf("lift:20,20", "move:0,100", "move:40,0", "land:true"), grip.calls)
    }

    @Test
    fun `a carry the system takes back is cancelled`() {
        val grip = Recorder()
        val view = placedView(grip)
        touch(view, MotionEvent.ACTION_DOWN)
        hold()
        touch(view, MotionEvent.ACTION_CANCEL)
        assertEquals(listOf("lift:20,20", "cancel"), grip.calls)
    }

    @Test
    fun `a tap or a scroll still belongs to the widget`() {
        val grip = Recorder()
        val view = placedView(grip)
        touch(view, MotionEvent.ACTION_DOWN)
        touch(view, MotionEvent.ACTION_UP)
        touch(view, MotionEvent.ACTION_DOWN)
        touch(view, MotionEvent.ACTION_MOVE, y = 200f)
        touch(view, MotionEvent.ACTION_CANCEL)
        hold()
        assertEquals(emptyList<String>(), grip.calls)
    }
}
