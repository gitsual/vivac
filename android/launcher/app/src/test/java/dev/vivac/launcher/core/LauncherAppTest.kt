package dev.vivac.launcher.core

import android.content.Context
import android.view.View
import android.widget.TextView
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsNotEnabled
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
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.campamento.PhoneFacts
import dev.vivac.launcher.petate.AppShortcut
import dev.vivac.launcher.widgets.Grip
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
    private val grips = mutableMapOf<Int, Grip>()
    private val views = object : WidgetViews {
        override fun heightDp(id: Int, rows: Int) = if (rows > 0) rows * 90 else 120
        override fun view(context: Context, id: Int, widthDp: Float, rows: Int, grip: Grip): View {
            drawn += id
            grips[id] = grip
            return TextView(context).apply { text = "w$id"; setOnLongClickListener { grip.lift(0f, 0f); grip.land(moved = false); true } }
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
    fun `the dock has no petate tile, and a swipe or the search pill open the petate, back returns`() {
        show()
        compose.onNodeWithText("Petate").assertDoesNotExist()
        compose.runOnUiThread { launcher.openPetate(false) }
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
    fun `the facts card opens the phone's info, and the gear vivac's phone settings`() {
        show()
        compose.onNodeWithText("2026111301").performClick()
        assertEquals(listOf("about"), actions.calls)
        compose.onNodeWithContentDescription("Ajustes del sistema").performClick()
        compose.waitForIdle()
        assertEquals(Screen.SISTEMA, launcher.screen)
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
    fun `holding a widget goes straight into moving and resizing it, up to six rows, until you tap away`() {
        widgets.placed = mutableMapOf(1 to "Reloj", 2 to "Música")
        store.values["widgets"] = "1,2"
        show()
        compose.runOnUiThread { grips.getValue(2).lift(40f, 40f) }
        assertEquals(2, launcher.editing)
        compose.runOnUiThread { grips.getValue(2).land(moved = false) }
        assertEquals(2, launcher.editing)
        compose.onNodeWithText("2 filas").assertExists()
        compose.onNodeWithContentDescription("Más alto").tap()
        compose.onNodeWithText("3 filas").assertExists()
        repeat(3) { compose.onNodeWithContentDescription("Más alto").tap() }
        compose.onNodeWithText("6 filas").assertExists()
        compose.onNodeWithContentDescription("Más alto").assertIsNotEnabled()
        listOf("Antes", "Después", "Ladera nueva", "Quitar del campamento").forEach { compose.onNodeWithText(it).assertDoesNotExist() }
        compose.onNodeWithContentDescription("Más bajo").tap()
        compose.onNodeWithText("5 filas").assertExists()
        compose.onNodeWithText("CAMPAMENTO").performTouchInput { click() }
        // A tap is told from a double tap only once the double-tap time has passed.
        compose.mainClock.advanceTimeBy(500)
        compose.waitForIdle()
        assertEquals(null, launcher.editing)
        compose.onNodeWithText("5 filas").assertDoesNotExist()
    }

    @Test
    fun `dragging the size bar down makes the widget taller, up makes it shorter`() {
        widgets.placed = mutableMapOf(1 to "Reloj")
        store.values["widgets"] = "1"
        show()
        compose.runOnUiThread { launcher.editWidget(1) }
        compose.onNodeWithText("2 filas").performTouchInput { swipe(center, center + androidx.compose.ui.geometry.Offset(0f, 100.dp.toPx())) }
        compose.onNodeWithText("3 filas").assertExists()
        compose.onNodeWithText("3 filas").performTouchInput { swipe(center, center - androidx.compose.ui.geometry.Offset(0f, 100.dp.toPx())) }
        compose.onNodeWithText("2 filas").assertExists()
    }

    @Test
    fun `back leaves a widget's resizing first`() {
        widgets.placed = mutableMapOf(1 to "Reloj")
        store.values["widgets"] = "1"
        show()
        compose.runOnUiThread { launcher.editWidget(1) }
        compose.waitForIdle()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.waitForIdle()
        assertEquals(null, launcher.editing)
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
    }

    @Test
    fun `a lifted widget follows the finger as a picture of itself`() {
        widgets.placed = mutableMapOf(1 to "Reloj", 2 to "Tiempo")
        store.values["widgets"] = "1,2"
        show()
        compose.runOnUiThread { grips.getValue(2).lift(1f, 1f, Bitmap.createBitmap(20, 10, Bitmap.Config.ARGB_8888)) }
        compose.onNodeWithTag("widget:ghost").assertExists()
        compose.onNodeWithText("Tiempo").assertDoesNotExist()
        compose.runOnUiThread { grips.getValue(2).cancel() }
        compose.onNodeWithTag("widget:ghost").assertDoesNotExist()
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
        assertEquals(1, launcher.editing)
    }

    @Test
    fun `a widget carried by its grip lands where it is let go`() {
        widgets.placed = mutableMapOf(1 to "Reloj", 2 to "Tiempo")
        store.values["widgets"] = "1,2"
        show()
        val from = viewCentre("w2")
        val to = viewCentre("w1")
        compose.runOnUiThread { grips.getValue(2).lift(40f, 40f) }
        compose.waitForIdle()
        compose.runOnUiThread { grips.getValue(2).move(0f, to.y - from.y); grips.getValue(2).land(moved = true) }
        compose.waitForIdle()
        assertEquals(listOf(2, 1), launcher.board.ids)
        assertEquals(2, launcher.editing)
    }

    @Test
    fun `in a locked camp a held widget only opens its card`() {
        widgets.placed = mutableMapOf(1 to "Reloj", 2 to "Tiempo")
        store.values["widgets"] = "1,2"
        store.values["locked"] = "1"
        show()
        compose.runOnUiThread { grips.getValue(2).lift(1f, 1f); grips.getValue(2).move(0f, -300f); grips.getValue(2).land(moved = true) }
        compose.waitForIdle()
        assertEquals(listOf(1, 2), launcher.board.ids)
        compose.runOnUiThread { grips.getValue(2).lift(1f, 1f); grips.getValue(2).land(moved = false) }
        assertEquals(2, launcher.editing)
    }

    @Test
    fun `a widget carried over the route or let go after a cancel stays where it was`() {
        widgets.placed = mutableMapOf(1 to "Reloj", 2 to "Tiempo")
        store.values["widgets"] = "1,2"
        store.values["pinned"] = "app.organicmaps"
        show()
        compose.runOnUiThread { grips.getValue(1).lift(1f, 1f); grips.getValue(1).cancel() }
        compose.waitForIdle()
        assertEquals(listOf(1, 2), launcher.board.ids)
    }

    /** The centre of a widget's view, in the coordinates Compose lays the screen out in. */
    private fun viewCentre(text: String): androidx.compose.ui.geometry.Offset {
        var at = androidx.compose.ui.geometry.Offset.Zero
        compose.runOnUiThread {
            val root = compose.activity.findViewById<android.view.ViewGroup>(android.R.id.content).getChildAt(0)
            val v = find(root) { it is TextView && it.text == text }!!
            val a = IntArray(2).also { v.getLocationInWindow(it) }
            val r = IntArray(2).also { root.getLocationInWindow(it) }
            at = androidx.compose.ui.geometry.Offset(a[0] - r[0] + v.width / 2f, a[1] - r[1] + v.height / 2f)
        }
        return at
    }

    @Test
    fun `a shortcut is pinned from the menu, opens from its ladera, and is taken off from its own menu`() {
        actions.shortcuts = mapOf("app.organicmaps" to listOf(AppShortcut("home", "Ir a casa")))
        store.values["pinned"] = "app.organicmaps"
        show()
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithContentDescription("Poner «Ir a casa» en una ladera").tap()
        compose.waitForIdle()
        compose.runOnUiThread { launcher.showPage(1) }
        compose.waitForIdle()
        compose.onNodeWithText("Ir a casa").performClick()
        assertTrue("shortcut:app.organicmaps/home" in actions.calls)
        compose.onNodeWithText("Ir a casa").performTouchInput { longClick() }
        compose.onNodeWithText("Quitar «Ir a casa» de la ladera").tap()
        compose.waitForIdle()
        assertEquals(emptyList<String>(), launcher.board.shortcutsOf("app.organicmaps"))
    }

    @Test
    fun `an app is renamed from its menu`() {
        store.values["pinned"] = "app.organicmaps"
        show()
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Cambiar el nombre").tap()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Nombre de Organic Maps").performTextReplacement("Mapas")
        compose.onNodeWithText("Guardar").tap()
        compose.waitForIdle()
        compose.onNodeWithText("Mapas").assertExists()
        compose.onNodeWithText("Mapas").performTouchInput { longClick() }
        compose.onNodeWithText("Cambiar el nombre").tap()
        compose.onNodeWithText("Volver a «Organic Maps»").tap()
        compose.waitForIdle()
        compose.onNodeWithText("Organic Maps").assertExists()
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
        // The hint is for an empty ladera: under something, it would only add space to scroll into.
        compose.onNodeWithText("Mantén pulsado un widget o una app para traerlos a esta ladera.").assertDoesNotExist()
        compose.onAllNodesWithText("Termux").assertCountEquals(2)
        compose.onNodeWithContentDescription("Ladera 1, página 2 de 3").assertExists()
    }

    private fun centre(text: String) = compose.onNodeWithText(text, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.center

    /** Holds [from] past the long-press time, then carries it to [to]'s centre and lets go. */
    private fun carry(from: String, to: androidx.compose.ui.geometry.Offset) {
        val start = centre(from)
        compose.onNodeWithText(from, useUnmergedTree = true).performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(1_000)
        compose.onNodeWithText(from, useUnmergedTree = true).performTouchInput {
            val by = to - start
            repeat(10) { moveBy(by / 10f) }
            up()
        }
        compose.waitForIdle()
    }

    @Test
    fun `dragging a pitch onto another reorders the route`() {
        store.values["pinned"] = "app.organicmaps,com.android.settings"
        show()
        carry("Ajustes", centre("Organic Maps"))
        assertEquals(listOf("com.android.settings", "app.organicmaps"), launcher.home.pinned)
        assertEquals(emptyList<String>(), actions.calls)
    }

    @Test
    fun `dragging a dock app onto the route moves it there`() {
        store.values["pinned"] = "app.organicmaps"
        show()
        carry("Termux", centre("Organic Maps"))
        assertEquals(listOf("com.termux", "app.organicmaps"), launcher.home.pinned)
        assertEquals(false, "com.termux" in launcher.shownDock())
    }

    @Test
    fun `an app carried out of the petate starts the route, and the petate closes`() {
        show()
        compose.runOnUiThread { launcher.openPetate(false) }
        compose.waitForIdle()
        val tile = compose.onNodeWithText("Ajustes", useUnmergedTree = true)
        val start = centre("Ajustes")
        tile.performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(1_000)
        tile.performTouchInput { repeat(5) { moveBy(androidx.compose.ui.geometry.Offset(0f, -20f)) } }
        compose.waitForIdle()
        // The petate gives way to the camp as soon as the app is lifted.
        val target = centre("Suelta aquí para empezar la vía")
        tile.performTouchInput {
            val by = target - (start + androidx.compose.ui.geometry.Offset(0f, -100f))
            repeat(10) { moveBy(by / 10f) }
            up()
        }
        compose.waitForIdle()
        assertEquals(listOf("com.android.settings"), launcher.home.pinned)
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
        assertEquals(emptyList<String>(), actions.calls)
    }

    @Test
    fun `an app carried out of the petate and let go over nothing just closes it`() {
        show()
        compose.runOnUiThread { launcher.openPetate(false) }
        compose.waitForIdle()
        val tile = compose.onNodeWithText("Ajustes", useUnmergedTree = true)
        tile.performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(1_000)
        tile.performTouchInput { repeat(5) { moveBy(androidx.compose.ui.geometry.Offset(0f, -20f)) }; up() }
        compose.waitForIdle()
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
        assertEquals(emptyList<String>(), launcher.home.pinned)
    }

    @Test
    fun `in a locked camp holding and moving an app carries nothing`() {
        store.values["pinned"] = "app.organicmaps,com.android.settings"
        store.values["locked"] = "1"
        show()
        carry("Ajustes", centre("Organic Maps"))
        assertEquals(listOf("app.organicmaps", "com.android.settings"), launcher.home.pinned)
        compose.onNodeWithText("Suelta aquí para empezar la vía").assertDoesNotExist()
    }

    @Test
    fun `while vivac is not the home app the camp menu offers to make it so`() {
        actions.home = false
        show()
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Hacer de vivac tu app de inicio").tap()
        compose.waitForIdle()
        assertEquals("askHome", actions.calls.last())
        assertEquals(false, launcher.campMenu)
        actions.home = true
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Hacer de vivac tu app de inicio").assertDoesNotExist()
    }

    @Test
    fun `the camp menu shows the phone's wallpaper, which the window then draws`() {
        show()
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Fondo: el del teléfono").tap()
        compose.waitForIdle()
        assertTrue(launcher.showWallpaper)
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Cambiar el fondo de pantalla").tap()
        compose.waitForIdle()
        assertEquals("wallpaper", actions.calls.last())
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Fondo: noche de vivac").tap()
        compose.waitForIdle()
        assertEquals(false, launcher.showWallpaper)
    }

    @Test
    fun `an app's widgets are offered in its menu and added from there`() {
        widgets.offered = listOf(WidgetOption("app.organicmaps/.W", "Mapa", "Organic Maps", "app.organicmaps", "4 × 2"), WidgetOption("o/.W", "Otro", "Otra", "o", ""))
        store.values["pinned"] = "app.organicmaps"
        show()
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Otro").assertDoesNotExist()
        compose.onNodeWithText("Mapa · 4 × 2").tap()
        compose.waitForIdle()
        assertEquals(null, launcher.menu)
        assertEquals(1, launcher.board.ids.size)
    }

    @Test
    fun `a folder is made from an app's menu, takes a dragged app, opens, renames and gives apps back`() {
        store.values["pinned"] = "app.organicmaps,com.android.settings"
        store.values["widgets"] = "@com.termux:1"
        show()
        compose.runOnUiThread { launcher.showPage(1); launcher.openMenu("com.termux") }
        compose.waitForIdle()
        compose.onNodeWithText("Meter en una carpeta").tap()
        compose.onNodeWithText("Carpeta nueva").tap()
        compose.waitForIdle()
        val id = launcher.board.folderOf("com.termux")!!.id
        compose.onNodeWithContentDescription("Nombre de la carpeta").performTextReplacement("Consola")
        compose.onNodeWithContentDescription("Nombre de la carpeta").performImeAction()
        compose.runOnUiThread { launcher.closeFolder() }
        compose.waitForIdle()
        assertEquals("Consola", launcher.board.folder(id)?.name)
        // Into the folder from the route: carried onto the folder tile on the ladera, via the page edge.
        compose.runOnUiThread { launcher.showPage(0) }
        compose.waitForIdle()
        compose.onNodeWithText("Ajustes").performTouchInput { longClick() }
        compose.onNodeWithText("Meter en una carpeta").tap()
        compose.onNodeWithText("Consola · 1 apps").tap()
        compose.waitForIdle()
        assertEquals(listOf("com.termux", "com.android.settings"), launcher.board.folder(id)?.apps)
        compose.runOnUiThread { launcher.showPage(1) }
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Carpeta Consola, 2 apps").performClick()
        compose.waitForIdle()
        compose.onAllNodesWithText("Ajustes").onLast().performTouchInput { longClick() }
        compose.waitForIdle()
        assertEquals(null, launcher.board.folder(id))
        assertTrue(launcher.board.apps.contains("com.termux"))
    }

    @Test
    fun `a carried app dropped on a folder goes in`() {
        store.values["widgets"] = "%f1|Viaje|com.termux%3Bapp.organicmaps:1,@com.android.settings:1"
        show()
        compose.runOnUiThread { launcher.showPage(1) }
        compose.waitForIdle()
        val target = compose.onNodeWithContentDescription("Carpeta Viaje, 2 apps").fetchSemanticsNode().boundsInRoot.center
        carry("Ajustes", target)
        assertEquals(listOf("com.termux", "app.organicmaps", "com.android.settings"), launcher.board.folder("f1")?.apps)
        compose.onNodeWithContentDescription("Carpeta Viaje, 3 apps").performTouchInput { longClick() }
        compose.waitForIdle()
        assertEquals("f1", launcher.openFolder)
        compose.onAllNodesWithText("Organic Maps").onLast().tap()
        assertEquals("open:app.organicmaps", actions.calls.last())
        assertEquals(null, launcher.openFolder)
    }

    @Test
    fun `the settings screen changes every choice, and back closes it`() {
        show()
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Ajustes de vivac").tap()
        compose.waitForIdle()
        assertEquals(Screen.AJUSTES, launcher.screen)
        compose.onNodeWithText("Bloquear el campamento").performClick()
        compose.onNodeWithText("Fondo del teléfono").performClick()
        compose.onNodeWithText("Cambiar el fondo de pantalla").performClick()
        compose.onNodeWithText("Nombres bajo las apps").performClick()
        compose.onNodeWithText("5").performClick()
        compose.onNodeWithText("Activar los puntos de aviso").performScrollTo().performClick()
        compose.onNodeWithText("Número de avisos").performScrollTo().performClick()
        compose.onAllNodesWithText("Buscar")[0].tap()
        compose.onAllNodesWithText("Nada")[1].tap()
        compose.onNodeWithText("Doble toque apaga la pantalla").performScrollTo().performClick()
        compose.onNodeWithText("Pack de iconos").tap()
        compose.onNodeWithText("No hay ningún pack de iconos instalado. Busca «icon pack» en tu tienda de apps.").assertExists()
        compose.onNodeWithText("Los de cada app").tap()
        compose.onNodeWithText("Buscar en contactos").performScrollTo().performClick()
        compose.onNodeWithText("Buscar en el calendario").performScrollTo().performClick()
        compose.onNodeWithText("Guardar una copia del campamento").performScrollTo().performClick()
        compose.onNodeWithText("Restaurar una copia").performScrollTo().performClick()
        compose.waitForIdle()
        assertTrue(launcher.locked)
        assertTrue(launcher.showWallpaper)
        assertEquals(false, launcher.labels)
        assertEquals(5, launcher.columns)
        assertTrue(launcher.showCounts)
        assertEquals(Gesture.SEARCH, launcher.swipeUp)
        assertEquals(Gesture.NOTHING, launcher.swipeDown)
        assertTrue(launcher.doubleTapLock)
        assertEquals(IconStyle.ORIGINAL, launcher.iconStyle)
        assertTrue(launcher.searchContacts)
        assertTrue(launcher.searchCalendar)
        assertTrue(actions.calls.containsAll(listOf("wallpaper", "notificationAccess", "backup", "restore")))
        compose.onNodeWithText("Cerrar").performScrollTo().performClick()
        compose.waitForIdle()
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
    }

    @Test
    fun `an installed icon pack is chosen from the settings`() {
        actions.packs = listOf(IconPackInfo("a.pack", "Arcticons"))
        store.values["icons"] = "PACK"
        show()
        compose.runOnUiThread { launcher.openSettings() }
        compose.onNodeWithText("Arcticons").tap()
        compose.waitForIdle()
        assertEquals("a.pack", launcher.iconPack)
        compose.onNodeWithText("Las apps sin icono en este estilo siguen con su glifo de vivac.").assertExists()
    }

    @Test
    fun `an app's icon is changed from its menu`() {
        store.values["pinned"] = "app.organicmaps"
        show()
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Cambiar el icono").tap()
        compose.waitForIdle()
        compose.onNodeWithText("Con un pack de iconos instalado podrás elegir cualquiera de sus iconos.").assertExists()
        compose.onNodeWithText("Icono de la app").tap()
        compose.waitForIdle()
        assertEquals(IconOverride.App, launcher.iconFor["app.organicmaps"])
        actions.packs = listOf(IconPackInfo("a.pack", "Arcticons"))
        compose.runOnUiThread { launcher.openMenu("app.organicmaps") }
        compose.onNodeWithText("Cambiar el icono").tap()
        compose.onNodeWithText("Arcticons").assertExists()
        compose.onNodeWithContentDescription("Buscar icono en el pack").performTextInput("map")
        compose.onNodeWithText("Como las demás").tap()
        compose.waitForIdle()
        assertEquals(null, launcher.iconFor["app.organicmaps"])
    }

    @Test
    fun `a swipe is set to open an app chosen in the settings`() {
        show()
        compose.runOnUiThread { launcher.openSettings() }
        compose.onAllNodesWithText("Abrir una app")[0].tap()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Qué app abre: Deslizar hacia arriba").performTextInput("org")
        compose.onNodeWithText("Organic Maps").tap()
        compose.waitForIdle()
        assertEquals(Gesture.APP, launcher.swipeUp)
        assertEquals("app.organicmaps", launcher.swipeUpApp)
        compose.onNodeWithText("Deslizar hacia arriba: Organic Maps").assertExists()
    }

    @Test
    fun `settings offer to make vivac the home app while it is not`() {
        actions.home = false
        show()
        compose.runOnUiThread { launcher.openSettings() }
        compose.waitForIdle()
        compose.onNodeWithText("vivac como app de inicio").performClick()
        assertEquals("askHome", actions.calls.last())
    }

    @Test
    fun `tiles show how many notifications when you chose counts, and hide names when you chose so`() {
        store.values["pinned"] = "app.organicmaps"
        store.values["counts"] = "1"
        store.values["labels"] = "0"
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets).also { it.refresh() }
        compose.setContent {
            CompositionLocalProvider(LocalDots provides setOf("app.organicmaps", "com.termux"), dev.vivac.launcher.apps.LocalCounts provides mapOf("app.organicmaps" to 3, "com.termux" to 120)) {
                LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, views)
            }
        }
        compose.onNodeWithText("3").assertExists()
        compose.onNodeWithText("99+").assertExists()
        compose.onNodeWithText("Organic Maps").assertDoesNotExist()
        compose.onNodeWithContentDescription("Organic Maps").assertExists()
        compose.runOnUiThread { launcher.onSwipeUp() }
        compose.waitForIdle()
        compose.onNodeWithText("Ajustes").assertDoesNotExist()
    }

    @Test
    fun `the camp menu locks and unlocks the layout`() {
        show()
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Bloquear el campamento").tap()
        compose.waitForIdle()
        assertTrue(launcher.locked)
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Desbloquear el campamento").tap()
        compose.waitForIdle()
        assertEquals(false, launcher.locked)
        compose.runOnUiThread { launcher.openCampMenu() }
        compose.onNodeWithText("Doble toque: apagar la pantalla").tap()
        compose.waitForIdle()
        assertTrue(launcher.doubleTapLock)
        actions.lockService = true
        compose.onNodeWithText("CAMPAMENTO").performTouchInput { doubleClick() }
        compose.waitForIdle()
        assertEquals("lock", actions.calls.last())
    }

    @Test
    fun `a pinned shortcut and a folder are carried to another place on their ladera`() {
        store.values["widgets"] = "@com.android.settings:1,#app.organicmaps|home|Casa:1,%f1|Viaje|com.termux%3Bapp.organicmaps:1"
        show()
        compose.runOnUiThread { launcher.showPage(1) }
        compose.waitForIdle()
        carry("Casa", centre("Ajustes"))
        assertTrue(launcher.board.onPage(1).first() is dev.vivac.launcher.campamento.Pinned)
        val folder = compose.onNodeWithContentDescription("Carpeta Viaje, 2 apps").fetchSemanticsNode().boundsInRoot.center
        val first = centre("Casa")
        compose.onNodeWithContentDescription("Carpeta Viaje, 2 apps").performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(1_000)
        compose.onNodeWithContentDescription("Carpeta Viaje, 2 apps").performTouchInput {
            val by = first - folder
            repeat(10) { moveBy(by / 10f) }
            up()
        }
        compose.waitForIdle()
        assertTrue(launcher.board.onPage(1).first() is dev.vivac.launcher.campamento.Folder)
    }

    @Test
    fun `letting go over nothing leaves everything where it was`() {
        store.values["pinned"] = "app.organicmaps"
        show()
        carry("Organic Maps", centre("CAMPAMENTO"))
        assertEquals(listOf("app.organicmaps"), launcher.home.pinned)
    }

    @Test
    fun `past the last ladera an empty one has a plus in the middle that adds apps to it`() {
        show()
        compose.runOnUiThread { launcher.showPage(launcher.board.pages) }
        compose.waitForIdle()
        compose.onNodeWithText("LADERA 1").assertExists()
        compose.onNodeWithContentDescription("Añadir apps a esta ladera").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("AÑADIR A LA LADERA 1").assertExists()
        compose.onNodeWithTag("adder:com.termux").performClick()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Termux, en esta ladera").assertExists()
        compose.runOnUiThread { launcher.closeAdder() }
        compose.waitForIdle()
        compose.onAllNodesWithText("Termux").assertCountEquals(2)
        compose.onNodeWithContentDescription("Añadir apps a esta ladera").assertDoesNotExist()
        // And one more past it.
        compose.onNodeWithContentDescription("Ladera 1, página 2 de 3").assertExists()
    }

    @Test
    fun `an app carried over a free cell of a ladera lands in that cell, empty cells before it`() {
        store.values["dock"] = "com.android.settings"
        store.values["widgets"] = "@com.termux:1"
        show()
        compose.runOnUiThread { launcher.showPage(1) }
        compose.waitForIdle()
        val cell = compose.onNodeWithTag("cell:1:6").fetchSemanticsNode().boundsInRoot.center
        carry("Termux", cell)
        assertEquals(List(6) { dev.vivac.launcher.campamento.Gap(1) } + dev.vivac.launcher.campamento.Shelved("com.termux", 1), launcher.board.onPage(1))
    }

    private fun withNotices(vararg avisos: dev.vivac.launcher.avisos.Aviso): FakeNotices {
        val notices = FakeNotices(avisos.toList())
        actions.dotsOn = true
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets, notices = notices).also { it.refresh() }
        compose.setContent { LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, views) }
        compose.runOnUiThread { launcher.onSwipeDown() }
        compose.waitForIdle()
        return notices
    }

    private fun aviso(key: String, title: String, pkg: String = "com.termux", reply: Boolean = false) =
        dev.vivac.launcher.avisos.Aviso(key, pkg, title, "texto de $title", System.currentTimeMillis(), ongoing = false, clearable = true, summary = false, canReply = reply)

    @Test
    fun `vivac's shade shows each app's notices, which open, go, are answered, or all go at once`() {
        val notices = withNotices(aviso("a", "Ana", reply = true), aviso("b", "Bea"), aviso("c", "Ruta", pkg = "app.organicmaps"))
        compose.onNodeWithText("Avisos").assertExists()
        compose.onNodeWithText("TERMUX").assertExists()
        compose.onNodeWithText("ORGANIC MAPS").assertExists()
        compose.onNodeWithText("texto de Ana").assertExists()
        compose.onNodeWithText("Responder").performClick()
        compose.onNodeWithContentDescription("Respuesta").performTextInput("voy")
        compose.onNodeWithContentDescription("Enviar respuesta").performClick()
        compose.onAllNodesWithContentDescription("Descartar")[0].performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Borrar todo").performClick()
        compose.waitForIdle()
        assertEquals(listOf("reply:a:voy", "dismiss:a", "dismissAll"), notices.calls)
        compose.onNodeWithText("Sin avisos. Todo en calma en el campamento.").assertExists()
    }

    @Test
    fun `tapping a notice opens it and the shade's switches reach the phone`() {
        val notices = withNotices(aviso("a", "Ana"))
        compose.onNodeWithContentDescription("Linterna").performClick()
        compose.onNodeWithContentDescription("Volumen").performClick()
        compose.onNodeWithContentDescription("Android").performClick()
        compose.onNodeWithTag("aviso:a").performClick()
        compose.waitForIdle()
        assertEquals(listOf("open:a"), notices.calls)
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
        assertTrue(actions.calls.containsAll(listOf("torch:true", "page:VOLUMEN", "notifications")))
    }

    @Test
    fun `the gear opens vivac's phone settings, whose rows open Android's pages or vivac's own`() {
        show()
        compose.onNodeWithContentDescription("Ajustes del sistema").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Teléfono").assertExists()
        compose.onNodeWithText("Batería").performClick()
        assertEquals("page:BATERIA", actions.calls.last())
        compose.onNodeWithText("Ajustes de vivac").performClick()
        compose.waitForIdle()
        assertEquals(Screen.AJUSTES, launcher.screen)
    }

    @Test
    fun `coming back from Android after allowing notification access, vivac's settings no longer offer it`() {
        show()
        compose.runOnUiThread { launcher.openSettings() }
        compose.waitForIdle()
        compose.onNodeWithText("Activar los puntos de aviso").assertExists()
        // You go to Android's page, allow it, and come back.
        compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
        actions.dotsOn = true
        compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
        compose.waitForIdle()
        compose.onNodeWithText("Activar los puntos de aviso").assertDoesNotExist()
    }
}
