package dev.vivac.launcher.core

import android.content.Context
import android.view.View
import android.widget.TextView
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.runtime.CompositionLocalProvider
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.graphics.toArgb
import dev.vivac.launcher.theme.Ink
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import dev.vivac.launcher.apps.LocalDots
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.campamento.PhoneFacts
import dev.vivac.launcher.petate.AppShortcut
import dev.vivac.launcher.widgets.WidgetOption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LauncherAppTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val termux = InstalledApp("Termux", "com.termux", false)
    private val maps = InstalledApp("Organic Maps", "app.organicmaps", false)
    private val settings = InstalledApp("Ajustes", "com.android.settings", true)
    private val facts = PhoneFacts("2026111301", "1 nov 2026", 25, 117, 99, true)
    private val clock = WidgetOption("clock/Clock", "Reloj", "Reloj", "clock", "2 × 2")

    private val store = FakeStore()
    private val actions = FakeActions()
    private val widgets = FakeWidgets()
    private val drawn = mutableListOf<Int>()
    private val views = object : WidgetViews {
        override fun heightDp(id: Int, rows: Int) = if (rows > 0) rows * 90 else 120
        override fun view(context: Context, id: Int, widthDp: Float, rows: Int, onLongPress: () -> Unit): View {
            drawn += id
            return TextView(context).apply { text = "w$id"; setOnLongClickListener { onLongPress(); true } }
        }
    }
    private lateinit var launcher: Launcher

    /**
     * Sheets live in their own dialog window, and Robolectric does not route injected touches
     * there; the click action is the one TalkBack uses. Real touches are checked on the phone.
     */
    private fun SemanticsNodeInteraction.tap() = performSemanticsAction(SemanticsActions.OnClick)

    private fun show(dots: Set<String> = emptySet(), apps: List<InstalledApp> = listOf(termux, maps, settings)) {
        launcher = Launcher(FakeSource(apps), store, actions, widgets).also { it.refresh() }
        compose.setContent {
            CompositionLocalProvider(LocalDots provides dots) { LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, views) }
        }
    }

    /** A 200dp drag (600px on the xxhdpi test screen) from the node's centre, well past the swipe threshold. */
    private fun SemanticsNodeInteraction.drag(dy: Float) = performTouchInput { swipe(center, center.copy(y = center.y + dy), 200) }

    @Test
    fun `the camp shows the stamp, the phone facts and the dock`() {
        show()
        compose.onNodeWithText("15:48").assertExists()
        compose.onNodeWithText("17").assertExists()
        compose.onNodeWithText("2026111301").assertExists()
        compose.onNodeWithText("25 GB").assertExists()
        compose.onNodeWithText("99 %").assertExists()
        compose.onNodeWithText("cargando").assertExists()
        compose.onNodeWithText("Termux").performClick()
        assertEquals(listOf("open:com.termux"), actions.calls)
    }

    @Test
    fun `the petate tile and the search pill open the petate, back returns`() {
        show()
        compose.onNodeWithText("Petate").performClick()
        compose.onNodeWithContentDescription("Buscar en el petate").assertExists()
        assertEquals(false, launcher.focusSearch)
        compose.runOnUiThread { launcher.back() }
        compose.onNodeWithText("buscar en el petate…").performClick()
        assertEquals(true, launcher.focusSearch)
        compose.onNodeWithText("Organic Maps").performClick()
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
        assertEquals(listOf("open:app.organicmaps"), actions.calls)
    }

    @Test
    fun `swiping up opens the petate and down pulls the shade`() {
        show()
        compose.onRoot().performTouchInput { swipeDown() }
        assertEquals(listOf("notifications"), actions.calls)
        compose.onRoot().performTouchInput { swipeUp() }
        compose.waitForIdle()
        assertEquals(Screen.PETATE, launcher.screen)
    }

    @Test
    fun `header and via card open the system pages`() {
        show()
        compose.onNodeWithContentDescription("Ajustes del sistema").performClick()
        compose.onNodeWithText("2026111301").performClick()
        assertEquals(listOf("settings", "about"), actions.calls)
    }

    @Test
    fun `long press on an app opens its menu, and its entries act`() {
        actions.shortcuts = mapOf("com.termux" to listOf(AppShortcut("s", "Nueva sesión")))
        show()
        compose.onNodeWithText("Termux").performTouchInput { longClick() }
        compose.onNodeWithText("com.termux").assertExists()
        compose.onNodeWithText("Fijar en el campamento").tap()
        compose.onNodeWithText("Vía del campamento").assertExists()
        compose.onNodeWithText("L1").assertExists()
        // Now both in the dock and pinned.
        compose.onAllNodesWithText("Termux").assertCountEquals(2)
        compose.onNodeWithText("Organic Maps").assertDoesNotExist()
        compose.onAllNodesWithText("Termux")[0].performTouchInput { longClick() }
        compose.onNodeWithText("Nueva sesión").tap()
        assertEquals(listOf("shortcut:com.termux/s"), actions.calls)
    }

    @Test
    fun `the menu names every entry for the app's state`() {
        actions.shortcutsReadable = false
        show()
        compose.onNodeWithText("Termux").performTouchInput { longClick() }
        listOf("Quitar del dock", "Fijar en el campamento", "Ocultar del petate", "Información de la app", "Desinstalar").forEach {
            compose.onNodeWithText(it).assertExists()
        }
        compose.onNodeWithText("Los atajos de cada app aparecen cuando vivac es tu app de inicio.").assertExists()
        compose.onNodeWithText("Desinstalar").tap()
        assertEquals(listOf("uninstall:com.termux"), actions.calls)
    }

    @Test
    fun `hidden apps are worded to come back`() {
        store.values["hidden"] = "app.organicmaps"
        show()
        compose.runOnUiThread { launcher.openPetate(false); launcher.openMenu("app.organicmaps") }
        compose.onNodeWithText("Mostrar en el petate").assertExists()
        compose.onNodeWithText("Información de la app").tap()
        assertEquals(listOf("info:app.organicmaps"), actions.calls)
    }

    @Test
    fun `long press on the camp opens its menu, which adds a widget through the picker`() {
        widgets.offered = listOf(clock)
        show()
        compose.onNodeWithText("LA CORDADA").performTouchInput { longClick() }
        compose.onNodeWithText("Activar puntos de aviso").assertExists()
        compose.onNodeWithText("Añadir widget").tap()
        compose.onNodeWithText("1 widgets de tus apps").assertExists()
        compose.onNodeWithText("2 × 2").assertExists()
        compose.onNodeWithText("Reloj").tap()
        compose.waitForIdle()
        assertEquals(listOf(1), launcher.board.ids)
        assertTrue(1 in drawn)
    }

    @Test
    fun `the camp menu removes a placed widget and offers dots only while they are off`() {
        widgets.placed = mutableMapOf(1 to "Reloj")
        store.values["widgets"] = "1"
        actions.dotsOn = true
        show()
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Activar puntos de aviso").assertDoesNotExist()
        compose.onNodeWithText("Quitar «Reloj»").tap()
        assertEquals(listOf("delete:1"), widgets.calls)
        assertTrue(launcher.board.ids.isEmpty())
    }

    @Test
    fun `allowing dots from the camp menu opens the system page`() {
        show()
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Activar puntos de aviso").tap()
        assertEquals(listOf("notificationAccess"), actions.calls)
    }

    @Test
    fun `swipes that start on a card still count`() {
        show()
        compose.onNodeWithText("BATERÍA").drag(600f)
        assertEquals(listOf("notifications"), actions.calls)
        compose.onNodeWithText("BATERÍA").drag(-600f)
        compose.waitForIdle()
        assertEquals(Screen.PETATE, launcher.screen)
    }

    @Test
    fun `the camp draws fully, with rope, contours, glyphs, dots and a widget`() {
        widgets.placed = mutableMapOf(1 to "Reloj")
        store.values += mapOf("widgets" to "1", "pinned" to "app.organicmaps")
        show(dots = setOf("com.termux", "app.organicmaps"))
        val root = compose.activity.window.decorView
        val bitmap = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        compose.runOnUiThread { root.draw(Canvas(bitmap)) }
        // The night ground, not an empty (transparent) frame; sampled at the right edge, clear of the beam.
        assertEquals(Ink.deep.toArgb(), bitmap.getPixel(root.width - 2, root.height * 3 / 4))
        assertTrue(1 in drawn)
        // Termux in the dock and Organic Maps pinned, each announced to TalkBack, not only coloured.
        compose.onAllNodes(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "con avisos")).assertCountEquals(2)
    }

    @Test
    fun `six pins make a route that turns at the wall's edge, numbered L1 to L6`() {
        val six = (1..6).map { InstalledApp("App $it", "p.a$it", false) }
        store.values["pinned"] = six.joinToString(",") { it.packageName }
        show(apps = six)
        compose.onNodeWithText("6 LARGOS · A MANO").assertExists()
        listOf("L1", "L4", "L5", "L6").forEach { compose.onNodeWithText(it).assertExists() }
        val root = compose.activity.window.decorView
        val bitmap = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        compose.runOnUiThread { root.draw(Canvas(bitmap)) }
    }

    @Test
    fun `a widget's card resizes it, sends it to a new ladera and takes it away`() {
        widgets.placed = mutableMapOf(1 to "Reloj", 2 to "Música")
        store.values["widgets"] = "1,2"
        show()
        compose.runOnUiThread { launcher.openWidgetMenu(2) }
        compose.onNodeWithText("Música").assertExists()
        compose.onNodeWithText("2 filas").assertExists()
        compose.onNodeWithContentDescription("Más alto").tap()
        compose.onNodeWithText("3 filas").assertExists()
        compose.onNodeWithText("Antes").tap()
        assertEquals(listOf(2, 1), launcher.board.ids)
        compose.onNodeWithText("Ladera nueva").tap()
        compose.waitForIdle()
        assertEquals(1, launcher.page)
        compose.onNodeWithText("LADERA 1").assertExists()
        compose.onNodeWithContentDescription("Ladera 1, página 2 de 2").assertExists()
        compose.runOnUiThread { launcher.openWidgetMenu(2) }
        compose.onNodeWithText("Quitar del campamento").tap()
        assertEquals(listOf(1), launcher.board.ids)
        assertEquals(1, launcher.board.pages)
    }

    @Test
    fun `holding a widget opens its card`() {
        widgets.placed = mutableMapOf(1 to "Reloj")
        store.values["widgets"] = "1"
        show()
        compose.runOnUiThread { compose.activity.window.decorView.findViewWithTag<View>(null) }
        compose.runOnUiThread {
            val v = compose.activity.window.decorView.rootView.let { root -> find(root) { it is TextView && it.text == "w1" } }
            v!!.performLongClick()
        }
        assertEquals(1, launcher.widgetMenu)
    }

    private fun find(v: View, match: (View) -> Boolean): View? {
        if (match(v)) return v
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i), match)?.let { return it }
        return null
    }

    @Test
    fun `an app put on a ladera shows there, and the dots say where you are`() {
        show()
        compose.onNodeWithText("Termux").performTouchInput { longClick() }
        compose.onNodeWithText("Poner en una ladera").tap()
        compose.waitForIdle()
        compose.runOnUiThread { launcher.showPage(1) }
        compose.waitForIdle()
        compose.onNodeWithText("LADERA 1").assertExists()
        compose.onNodeWithText("Mantén pulsado un widget o una app para traerlos a esta ladera.").assertExists()
        compose.onAllNodesWithText("Termux").assertCountEquals(2)
        compose.onNodeWithContentDescription("Ladera 1, página 2 de 2").assertExists()
    }
}
