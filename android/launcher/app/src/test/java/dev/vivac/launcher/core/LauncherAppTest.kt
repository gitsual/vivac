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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.performMultiModalInput
import androidx.compose.ui.test.pinch
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.swipeLeft
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
import dev.vivac.launcher.avisos.Control
import dev.vivac.launcher.avisos.Quick
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        compose.onNodeWithText("25 GB").assertExists()
        compose.onNodeWithText("99 %").assertExists()
        // The battery's state is in its icon: no "cargando" written out, and no GrapheneOS build on the camp.
        compose.onNodeWithContentDescription("Batería al 99 %, cargando").assertExists()
        compose.onNodeWithText("cargando").assertDoesNotExist()
        compose.onNodeWithText("2026111301").assertDoesNotExist()
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
        // No search bar on the camp: the petate opens with a swipe up, its search inside.
        compose.onNodeWithText("buscar en el petate…").assertDoesNotExist()
        compose.runOnUiThread { launcher.openPetate(true) }
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
    fun `a pinch on the camp runs its gesture, and a two-finger drag is not also a swipe`() {
        store.values[TwoFinger.PINCH.key] = Gesture.NOTIFICATIONS.name
        store.values[TwoFinger.TWO_UP.key] = Gesture.SEARCH.name
        show()
        compose.onRoot().performTouchInput {
            pinch(Offset(centerX - 300f, centerY), Offset(centerX - 40f, centerY), Offset(centerX + 300f, centerY), Offset(centerX + 40f, centerY))
        }
        compose.waitForIdle()
        assertEquals(listOf("notifications"), actions.calls)
        compose.onRoot().performMultiModalInput {
            touch {
                down(0, Offset(centerX - 100f, centerY + 400f))
                down(1, Offset(centerX + 100f, centerY + 400f))
                repeat(10) { step ->
                    moveTo(0, Offset(centerX - 100f, centerY + 400f - 60f * (step + 1)))
                    moveTo(1, Offset(centerX + 100f, centerY + 400f - 60f * (step + 1)))
                }
                up(0)
                up(1)
            }
        }
        compose.waitForIdle()
        assertTrue(launcher.focusSearch)
        assertEquals(Screen.PETATE, launcher.screen)
    }

    @Test
    fun `the gear opens vivac's phone settings`() {
        show()
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
        compose.onNodeWithText("Vía del campamento").assertDoesNotExist()
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
        compose.onNodeWithText("LIBRE").performTouchInput { longClick() }
        compose.onNodeWithText("Activar puntos de aviso").assertExists()
        compose.onNodeWithText("Añadir widget").tap()
        compose.onNodeWithText("2 widgets").assertExists()
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
    fun `the petate draws as a bag, its cloth over the night, with cord, label, zip and strap`() {
        show()
        compose.runOnUiThread { launcher.openApp("com.termux"); launcher.openPetate(false) }
        compose.waitForIdle()
        compose.onNodeWithText("Petate").assertExists()
        val root = compose.activity.window.decorView
        val bitmap = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        compose.runOnUiThread { root.draw(Canvas(bitmap)) }
        // Inside the bag, down its left side, the cloth shows rather than the night behind it.
        assertTrue(bitmap.getPixel(root.width / 20, root.height * 3 / 4) != Ink.deep.toArgb())
    }

    @Test
    fun `six pins make a route that turns at the wall's edge, numbered L1 to L6`() {
        val six = (1..6).map { InstalledApp("App $it", "p.a$it", false) }
        store.values["pinned"] = six.joinToString(",") { it.packageName }
        show(apps = six)
        compose.onNodeWithText("6 LARGOS · A MANO").assertDoesNotExist()
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
        compose.onNodeWithText("LIBRE").performTouchInput { click() }
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

    @Test
    fun `an app's category is changed from its menu to a new one, an existing one, or android's again`() {
        store.values["pinned"] = "app.organicmaps"
        show()
        val category = { launcher.apps.first { it.packageName == "app.organicmaps" }.category }
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Cambiar la categoría").tap()
        compose.waitForIdle()
        compose.onNodeWithText("Guardar").tap()
        // A blank name saves nothing; the sheet stays.
        assertEquals(null, category())
        compose.onNodeWithContentDescription("Categoría nueva").performTextInput("Montaña")
        compose.onNodeWithText("Guardar").tap()
        compose.waitForIdle()
        assertEquals("Montaña", category())
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Cambiar la categoría").tap()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Categoría nueva").performTextInput("Viaje")
        compose.onNodeWithContentDescription("Categoría nueva").performImeAction()
        compose.waitForIdle()
        assertEquals("Viaje", category())
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Cambiar la categoría").tap()
        compose.waitForIdle()
        compose.onAllNodesWithText("Viaje").onLast().tap()
        compose.waitForIdle()
        assertEquals("Viaje", category())
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Cambiar la categoría").tap()
        compose.onNodeWithText("La de Android").tap()
        compose.waitForIdle()
        assertEquals(null, category())
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Cambiar la categoría").tap()
        compose.waitForIdle()
        compose.runOnUiThread { launcher.cancelCategory() }
        compose.waitForIdle()
        assertEquals(null, launcher.categorizing)
    }

    @Test
    fun `an app with a pause asks first, counts down, and opens only when you say so`() {
        store.values["pinned"] = "app.organicmaps"
        show()
        compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
        compose.onNodeWithText("Pausa antes de abrir").tap()
        compose.waitForIdle()
        // Without usage access: a breath, and a way to allow it.
        compose.runOnUiThread { launcher.openApp("app.organicmaps") }
        compose.waitForIdle()
        compose.onNodeWithText("UN MOMENTO").assertExists()
        compose.onNodeWithText("Ver cuánto la usas hoy").tap()
        assertEquals("usageAccess", actions.calls.last())
        compose.onNodeWithText("Ahora no").tap()
        compose.waitForIdle()
        assertEquals(null, launcher.pausing)
        // With it: today's use, and the open button wakes after the countdown.
        actions.usage["app.organicmaps"] = 42 * 60_000L
        compose.runOnUiThread { launcher.openApp("app.organicmaps") }
        compose.waitForIdle()
        compose.onNodeWithText("Hoy: 42 min").assertExists()
        compose.onNodeWithText("Abrir en 5").performClick()
        assertFalse("open:app.organicmaps" in actions.calls)
        compose.mainClock.advanceTimeBy(6_000)
        compose.waitForIdle()
        compose.onNodeWithText("Abrir").performClick()
        compose.waitForIdle()
        assertEquals("open:app.organicmaps", actions.calls.last())
    }

    @Test
    fun `a flick on a pinned app runs its own action, and the camp does not swipe as well`() {
        store.values["pinned"] = "app.organicmaps"
        store.values[Launcher.KEY_FLICK_FOR] = "app.organicmaps=" + java.net.URLEncoder.encode(Flick.App("com.termux").encode(), "UTF-8")
        show()
        compose.onNodeWithText("Organic Maps").performTouchInput { swipe(center, center - Offset(0f, 300f)) }
        compose.waitForIdle()
        assertEquals("open:com.termux", actions.calls.last())
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
        // An app without one: the swipe is the camp's.
        compose.onNodeWithText("Termux").performTouchInput { swipe(center, center - Offset(0f, 300f)) }
        compose.waitForIdle()
        assertEquals(Screen.PETATE, launcher.screen)
        // And a swipe that starts on a tile never opens that app as well.
        assertEquals(1, actions.calls.count { it == "open:com.termux" })
    }

    @Test
    fun `the flick sheet offers the app's shortcuts, any other app, or nothing`() {
        store.values["pinned"] = "app.organicmaps"
        actions.shortcuts = mapOf("app.organicmaps" to listOf(AppShortcut("home", "Ir a casa")))
        show()
        val open = {
            compose.onNodeWithText("Organic Maps").performTouchInput { longClick() }
            compose.onNodeWithText("Al deslizar sobre ella").tap()
            compose.waitForIdle()
        }
        open()
        compose.onNodeWithText("Ir a casa").tap()
        compose.waitForIdle()
        assertEquals(Flick.Shortcut("home", "Ir a casa"), launcher.flickOf("app.organicmaps"))
        open()
        compose.onAllNodesWithText("Termux").onLast().performScrollTo().performClick()
        compose.waitForIdle()
        assertEquals(Flick.App("com.termux"), launcher.flickOf("app.organicmaps"))
        open()
        compose.onNodeWithText("Nada").tap()
        compose.waitForIdle()
        assertEquals(null, launcher.flickOf("app.organicmaps"))
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
        compose.onNode(androidx.compose.ui.test.hasContentDescription("Ladera 1, página 2", substring = true)).assertExists()
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
        // Up to the hour, where the camp takes nothing.
        val climb = tile.fetchSemanticsNode().boundsInRoot.center.y - 300f
        tile.performTouchInput { repeat(5) { moveBy(androidx.compose.ui.geometry.Offset(0f, -climb / 5)) }; up() }
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
        compose.onNodeWithText("Oscuro").performScrollTo().performClick()
        compose.onNodeWithText("Desenfocar tu fondo").performScrollTo().performClick()
        compose.onNodeWithText("Desenfocar detrás de los menús").performScrollTo().performClick()
        compose.onNodeWithText("Nombres bajo las apps").performClick()
        compose.onNodeWithText("5").performScrollTo().performClick()
        compose.onNodeWithText("Activar los puntos de aviso").performScrollTo().performClick()
        compose.onNodeWithText("Número de avisos").performScrollTo().performClick()
        compose.onAllNodesWithText("Buscar")[0].tap()
        compose.onAllNodesWithText("Nada")[1].tap()
        compose.onNodeWithText("Doble toque apaga la pantalla").performScrollTo().performClick()
        compose.onAllNodesWithText("Ver los avisos").onLast().performScrollTo().performClick()
        compose.onNodeWithText("Apagar sin Accesibilidad").performScrollTo().performClick()
        compose.onNodeWithText("Pack de iconos").tap()
        compose.onNodeWithText("No hay ningún pack de iconos instalado. Busca «icon pack» en tu tienda de apps.").assertExists()
        compose.onNodeWithText("Los de cada app").tap()
        compose.onNodeWithText("Buscar en contactos").performScrollTo().performClick()
        compose.onNodeWithText("Pedir huella para ver las ocultas").performScrollTo().performClick()
        compose.onNodeWithText("Buscar en el calendario").performScrollTo().performClick()
        compose.onNodeWithText("Buscar en fotos, vídeos y música").performScrollTo().performClick()
        compose.onNodeWithText("Guardar una copia del campamento").performScrollTo().performClick()
        compose.onNodeWithText("Restaurar una copia").performScrollTo().performClick()
        compose.onNodeWithText("Importar de Nova o Lawnchair").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Nombre del perfil").performScrollTo().performTextInput("Viaje")
        compose.onNodeWithText("Guardar perfil").performScrollTo().performClick()
        compose.onNodeWithText("Viaje").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Borrar el perfil Viaje").performScrollTo().performClick()
        compose.onNodeWithText("Poner la noche de vivac").performScrollTo().performClick()
        compose.onNodeWithText("Volver a tu fondo").performScrollTo().performClick()
        compose.waitForIdle()
        assertTrue(launcher.locked)
        assertTrue(launcher.showWallpaper)
        assertTrue(launcher.protectHidden)
        assertEquals(Veil.OSCURO, launcher.veil)
        assertTrue("lockAdmin" in actions.calls)
        assertTrue(launcher.blurWallpaper)
        assertTrue(launcher.searchFiles)
        assertTrue("import" in actions.calls)
        assertEquals(Gesture.NOTIFICATIONS, launcher.gestureOf(TwoFinger.TWO_DOWN))
        assertFalse(launcher.blurSheets)
        assertEquals(emptyList<String>(), launcher.camps)
        assertTrue("say:Campamento «Viaje»." in actions.calls)
        assertTrue(actions.calls.containsAll(listOf("lockNight:true", "lockNight:false")))
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
        compose.onNodeWithText("LIBRE").performTouchInput { doubleClick() }
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
        carry("Organic Maps", centre("LIBRE"))
        assertEquals(listOf("app.organicmaps"), launcher.home.pinned)
    }

    @Test
    fun `past the last ladera an empty one has a plus in the middle that adds apps to it`() {
        show()
        compose.runOnUiThread { launcher.showPage(launcher.board.pages) }
        compose.waitForIdle()
        compose.onNode(androidx.compose.ui.test.hasContentDescription("Ladera 1, página 2", substring = true)).assertExists()
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

    /** Draws the whole window into a bitmap, as the screen would: the camp's drawings run for real. */
    private fun drawWindow() {
        val root = compose.activity.window.decorView
        val bitmap = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        compose.runOnUiThread { root.draw(android.graphics.Canvas(bitmap)) }
        assertTrue(bitmap.width > 0)
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

    /** A notice posted [minutesAgo] minutes ago, so the shade's order is fixed. */
    private fun aviso(key: String, title: String, pkg: String = "com.termux", reply: Boolean = false, minutesAgo: Long = 0) =
        dev.vivac.launcher.avisos.Aviso(key, pkg, title, "texto de $title", System.currentTimeMillis() - minutesAgo * 60_000, ongoing = false, clearable = true, summary = false, canReply = reply)

    @Test
    fun `vivac's shade shows each app's notices, which open, go, are answered, or all go at once`() {
        val notices = withNotices(aviso("a", "Ana", reply = true), aviso("b", "Bea", minutesAgo = 1), aviso("c", "Ruta", pkg = "app.organicmaps", minutesAgo = 5))
        compose.onNodeWithText("Avisos").assertExists()
        compose.onNodeWithText("TERMUX").assertExists()
        drawWindow()
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
        compose.onNodeWithContentDescription("Linterna, activado").assertExists()
        compose.onNodeWithContentDescription("Wi-Fi").performClick()
        // Whole pages of eight: the last switches are two swipes away, never half shown at the edge.
        compose.onNodeWithContentDescription("Cortina de Android").assertDoesNotExist()
        compose.onNodeWithContentDescription("Atajos, página 1 de 3").assertExists()
        repeat(2) {
            compose.onNodeWithTag("quick:pages").performTouchInput { swipeLeft() }
            compose.waitForIdle()
        }
        compose.onNodeWithContentDescription("Atajos, página 3 de 3").assertExists()
        compose.onNodeWithContentDescription("Cortina de Android").performClick()
        compose.onNodeWithTag("aviso:a").performScrollTo().performClick()
        compose.waitForIdle()
        assertEquals(listOf("open:a"), notices.calls)
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
        assertTrue(actions.calls.containsAll(listOf("torch:true", "page:WIFI", "notifications")))
    }

    @Test
    fun `the shade's switches are edited in place, taken out, moved, added, apps too`() {
        withNotices()
        compose.onNodeWithText("Editar").performClick()
        compose.onNodeWithContentDescription("Wi-Fi").performClick()
        compose.onNodeWithContentDescription("Mover después").performClick()
        compose.waitForIdle()
        assertEquals(Quick.Of(Control.WIFI), launcher.quick[1])
        compose.onNodeWithText("Quitar").performClick()
        compose.onNodeWithContentDescription("Añadir NFC").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Añadir Apps").performScrollTo().performClick()
        compose.waitForIdle()
        compose.onNodeWithText("ATAJOS DE LA CORTINA").assertExists()
        compose.onNodeWithTag("adder:com.termux").performClick()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Termux, en la cortina").assertExists()
        compose.runOnUiThread { launcher.closeQuickApps() }
        compose.waitForIdle()
        compose.onNodeWithText("Hecho").performScrollTo().performClick()
        compose.waitForIdle()
        assertFalse(launcher.editingQuick)
        assertFalse(Quick.Of(Control.WIFI) in launcher.quick)
        assertEquals(listOf(Quick.Of(Control.NFC), Quick.App("com.termux")), launcher.quick.takeLast(2))
    }

    @Test
    fun `a notice swiped away goes, an app's notices go together, and its notification settings open`() {
        val notices = withNotices(aviso("a", "Ana"), aviso("b", "Bea", minutesAgo = 1), aviso("c", "Ruta", pkg = "app.organicmaps", minutesAgo = 5))
        compose.onNodeWithTag("swipe:c").performScrollTo().performTouchInput { swipeLeft() }
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Ajustes de los avisos de Termux").performScrollTo().performClick()
        assertEquals("noticeSettings:com.termux", actions.calls.last())
        compose.onNodeWithContentDescription("Descartar los de Termux").performScrollTo().performClick()
        compose.waitForIdle()
        assertEquals(listOf("dismiss:c", "dismiss:a", "dismiss:b"), notices.calls)
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

    @Test
    fun `swiping one notice inside an app's card takes only that one, the next stays in view`() {
        val notices = withNotices(aviso("a", "Ana"), aviso("b", "Bea", minutesAgo = 1))
        compose.onNodeWithTag("swipe:a").performTouchInput { swipeLeft() }
        compose.waitForIdle()
        assertEquals(listOf("dismiss:a"), notices.calls)
        compose.onNodeWithText("texto de Bea").assertIsDisplayed()
    }

    @Test
    fun `while something is carried to another page, the page it came from stays alive under the finger`() {
        store.values["widgets"] = "@com.termux:1"
        val drag = dev.vivac.launcher.campamento.DragBoard()
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets).also { it.refresh() }
        compose.setContent { LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, views, drag) }
        compose.runOnUiThread { drag.pick(dev.vivac.launcher.campamento.HeldWidget(1, Zone.Ladera(0), "Reloj"), androidx.compose.ui.geometry.Offset(10f, 10f)) }
        compose.runOnUiThread { launcher.showPage(1) }
        compose.mainClock.advanceTimeBy(3_000)
        compose.waitForIdle()
        // The ladera has turned into view...
        compose.onNodeWithTag("cell:1:1").assertIsDisplayed()
        // ...and the camp, where the widget's own view still holds the finger, is not torn down.
        compose.onNodeWithText("25 GB").assertExists()
    }

    @Test
    fun `two quick swipes back in a row land two pages back, the first never pulls you forward again`() {
        store.values["widgets"] = "@com.termux:1,@app.organicmaps:2"
        show()
        compose.runOnUiThread { launcher.showPage(2) }
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        // The second swipe starts while the first is still settling.
        compose.onRoot().performTouchInput { swipeRight(startX = width * 0.2f, endX = width * 0.9f, durationMillis = 120) }
        compose.mainClock.advanceTimeBy(250)
        compose.onRoot().performTouchInput { swipeRight(startX = width * 0.2f, endX = width * 0.9f, durationMillis = 120) }
        compose.mainClock.autoAdvance = true
        compose.mainClock.advanceTimeBy(3_000)
        compose.waitForIdle()
        assertEquals(0, launcher.page)
    }

    @Test
    fun `vivac's settings switch the widgets' tint`() {
        show()
        compose.runOnUiThread { launcher.openSettings() }
        compose.waitForIdle()
        compose.onNodeWithText("Widgets con los colores de vivac").performScrollTo().performClick()
        compose.waitForIdle()
        assertFalse(launcher.tintWidgets)
    }

    @Test
    @org.robolectric.annotation.Config(qualifiers = "w914dp-h411dp-land-420dpi")
    fun `turned on its side, the shade puts its switches left and the notices right, at full height`() {
        withNotices(aviso("a", "Ana"), aviso("b", "Bea", minutesAgo = 1))
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        val screen = compose.onRoot().fetchSemanticsNode().boundsInRoot
        val wifi = compose.onNodeWithText("Wi-Fi").fetchSemanticsNode().boundsInRoot
        val list = compose.onNodeWithTag("avisos:list").fetchSemanticsNode().boundsInRoot
        val ana = compose.onNodeWithText("Ana").fetchSemanticsNode().boundsInRoot
        // The switches on the left, the notices beside them: both in sight at once, the notices whole.
        assertTrue("wifi $wifi, list $list", wifi.right <= list.left)
        assertTrue("list $list on $screen", list.width > screen.width * 0.45f && list.height > screen.height * 0.6f)
        assertTrue("ana $ana on $screen", ana.bottom <= screen.bottom && ana.left >= list.left)
        // "Borrar todo" belongs to the notices, under them, not over the switches.
        val clear = compose.onNodeWithText("Borrar todo").fetchSemanticsNode().boundsInRoot
        assertTrue("clear $clear, list $list", clear.left >= list.left && clear.top >= list.bottom - 1f)
    }

    @Test
    fun `the shade's contour lines travel outwards from the lamp's corner, as on the camp`() {
        withNotices(aviso("a", "Ana"))
        val rings = compose.onNodeWithTag("rings").fetchSemanticsNode().boundsInRoot
        val screen = compose.onRoot().fetchSemanticsNode().boundsInRoot
        assertEquals(screen.width, rings.width, 1f)
    }

    @Test
    fun `pulling up past the end of the notices closes the shade back to the camp`() {
        withNotices(aviso("a", "Ana"))
        compose.onNodeWithTag("avisos:list").performTouchInput { swipeUp() }
        compose.waitForIdle()
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
    }

    @Test
    fun `pulling down from the top of the notices also closes the shade`() {
        withNotices(aviso("a", "Ana"))
        compose.onNodeWithTag("avisos:list").performTouchInput { swipeDown() }
        compose.waitForIdle()
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
    }

    @Test
    fun `scrolling inside a widget on the camp scrolls the widget, it does not open the petate`() {
        widgets.placed[1] = "chat"
        store.values["widgets"] = "1"
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets).also { it.refresh() }
        val real = object : WidgetViews {
            override fun heightDp(id: Int, rows: Int) = 300
            override fun view(context: Context, id: Int, widthDp: Float, rows: Int, grip: Grip): View =
                dev.vivac.launcher.widgets.WidgetFrame(context).apply {
                    // A list inside the widget that takes the finger, as a chat widget's does.
                    addView(android.widget.ScrollView(context).apply {
                        addView(android.widget.LinearLayout(context).apply {
                            orientation = android.widget.LinearLayout.VERTICAL
                            repeat(40) { n -> addView(TextView(context).apply { text = "chat $n"; minHeight = 120 }) }
                        })
                    })
                    contentDescription = "widget-chat"
                }
        }
        compose.setContent { LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, real) }
        compose.waitForIdle()
        compose.onNodeWithTag("widget:1").performTouchInput { swipeUp() }
        compose.waitForIdle()
        assertEquals(Screen.CAMPAMENTO, launcher.screen)
    }

    @Test
    // The Pixel 8: 1080 × 2400 px at 420 dpi, so the hour gets the room it has on the phone.
    @org.robolectric.annotation.Config(qualifiers = "w411dp-h914dp-420dpi")
    fun `the widest hours fit beside the date without running under it`() {
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets).also { it.refresh() }
        var stamp by androidx.compose.runtime.mutableStateOf("mié 18 nov · 02:00")
        compose.setContent { LauncherApp(launcher, stamp, facts, actions, views) }
        for (hour in listOf("02:00", "12:00", "00:00", "20:08")) {
            compose.runOnUiThread { stamp = "mié 18 nov · $hour" }
            compose.waitForIdle()
            val node = compose.onNodeWithText(hour).fetchSemanticsNode()
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            node.config[androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult].action?.invoke(layouts)
            val layout = layouts.single()
            assertEquals("$hour on one line", 1, layout.lineCount)
            assertTrue("$hour drawn past its box", layout.getLineRight(0) <= layout.size.width)
            val date = compose.onNodeWithText("18").fetchSemanticsNode().boundsInRoot
            assertTrue("$hour runs under the date", node.boundsInRoot.left + layout.size.width <= date.left)
        }
    }

    @Test
    @org.robolectric.annotation.Config(qualifiers = "w411dp-h914dp-420dpi")
    fun `the route sits in the middle of the room between the camp's facts and the dock`() {
        store.values["pinned"] = "com.termux,app.organicmaps,com.android.settings"
        show()
        val facts = compose.onNodeWithText("LIBRE").fetchSemanticsNode().boundsInRoot
        val route = compose.onNodeWithTag("via").fetchSemanticsNode().boundsInRoot
        val dock = compose.onNodeWithContentDescription("Dock").fetchSemanticsNode().boundsInRoot
        val above = route.top - facts.bottom
        val below = dock.top - route.bottom
        val dp = compose.activity.resources.displayMetrics.density
        assertTrue("above $above below $below", above > 48 * dp && kotlin.math.abs(above - below) < 48 * dp)
    }

    @Test
    @org.robolectric.annotation.Config(qualifiers = "w411dp-h914dp-420dpi")
    fun `with room to spare the route's rows spread apart`() {
        val eight = (1..8).map { InstalledApp("App $it", "p.a$it", false) }
        store.values["pinned"] = eight.joinToString(",") { it.packageName }
        show(apps = eight)
        compose.waitForIdle()
        val first = compose.onNodeWithText("App 1").fetchSemanticsNode().boundsInRoot
        val second = compose.onNodeWithText("App 5").fetchSemanticsNode().boundsInRoot
        val dp = compose.activity.resources.displayMetrics.density
        // From the bottom of a row's name to the top of the next row's tile, well past the old 10dp.
        assertTrue("rows ${(second.top - first.bottom) / dp}dp apart", second.top - first.bottom > 40 * dp)
    }

    @Test
    @org.robolectric.annotation.Config(qualifiers = "w411dp-h914dp-420dpi")
    fun `the route's rows hold still once laid out`() {
        val eight = (1..8).map { InstalledApp("App $it", "p.a$it", false) }
        store.values["pinned"] = eight.joinToString(",") { it.packageName }
        show(apps = eight)
        compose.waitForIdle()
        fun spots() = listOf("App 1", "App 8").map { compose.onNodeWithText(it).fetchSemanticsNode().boundsInRoot.top }
        val settled = spots()
        compose.mainClock.autoAdvance = false
        val seen = (1..30).map { compose.mainClock.advanceTimeByFrame(); spots() }
        compose.mainClock.autoAdvance = true
        assertTrue("rows moved after settling: $settled then ${seen.distinct()}", seen.all { it == settled })
    }

    @Test
    fun `free space is a memory card filled with what is free, read out as free of the total`() {
        show()
        compose.onNodeWithContentDescription("25 GB libres de 117").assertExists()
        compose.onNodeWithTag("free:card", useUnmergedTree = true).assertExists()
    }

    @Test
    fun `the settings lamp is a bar-sized icon alone in its ring, the other icons kept outside it`() {
        show()
        val dp = compose.activity.resources.displayMetrics.density
        val lamp = compose.onNodeWithContentDescription("Ajustes del sistema").fetchSemanticsNode().boundsInRoot
        val links = compose.onNode(androidx.compose.ui.test.hasContentDescription("obertura", substring = true))
        val near = links.fetchSemanticsNode().boundsInRoot
        // A 44dp touch target, its ring 26dp around the centre: the connections end clear of the ring.
        assertEquals(44f * dp, lamp.width, 1f)
        assertTrue("connections end ${(lamp.center.x - near.right) / dp}dp from the lamp", lamp.center.x - near.right >= 26 * dp + 8 * dp)
    }

    @Test
    fun `under the switches, a brightness bar sets the screen's brightness`() {
        withNotices()
        compose.onNodeWithContentDescription("Brillo").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { it(0.9f) }
        compose.waitForIdle()
        assertEquals(0.9f, launcher.brightness, 0.01f)
    }

    @Test
    fun `swiping an app's card to the right takes its notices away`() {
        val notices = withNotices(aviso("a", "Ana"), aviso("b", "Bea", minutesAgo = 1), aviso("c", "Ruta", pkg = "app.organicmaps", minutesAgo = 5))
        compose.onNodeWithTag("card:app.organicmaps").performScrollTo().performTouchInput { swipeRight(startX = width * 0.3f, endX = width.toFloat()) }
        compose.waitForIdle()
        assertEquals(listOf("dismiss:c"), notices.calls)
    }

    @Test
    fun `the at a glance widget shows the next alarm, the next event and what is playing, and acts on each`() {
        actions.alarm = java.time.LocalDate.of(2026, 11, 20).atTime(7, 30).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        store.values["vivacWidgets"] = "-1=vivac:glance:dev.vivac.launcher"
        store.values["widgets"] = "-1"
        store.values["searchCalendar"] = "1"
        val dir = FakeDirectory().apply { calendarAllowed = true; agenda = listOf(CalendarEvent(5, "Cena con Ana", 0L)) }
        val notices = FakeNotices()
        notices.playing.value = NowPlaying("Canción", "Grupo", "com.termux", playing = true)
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets, notices = notices, directory = dir).also { it.refresh() }
        compose.setContent { LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, views) }
        compose.waitForIdle()
        compose.onNodeWithText("vie 20 nov · 07:30", substring = true).performClick()
        assertEquals("page:ALARMAS", actions.calls.last())
        compose.onNodeWithText("Cena con Ana").performClick()
        assertEquals(listOf("event:5"), dir.calls.filter { it.startsWith("event") })
        compose.onNodeWithText("Canción").performClick()
        assertEquals("open:com.termux", actions.calls.last())
        compose.onNodeWithContentDescription("Anterior").performClick()
        compose.onNodeWithContentDescription("Pausa").performClick()
        compose.onNodeWithContentDescription("Siguiente").performClick()
        assertEquals(listOf("media:PREVIOUS", "media:TOGGLE", "media:NEXT"), notices.calls)
        // Nothing to show: it says so.
        actions.alarm = null
        notices.playing.value = null
        compose.runOnUiThread { launcher.toggleCalendar() }
        compose.waitForIdle()
        compose.onNodeWithText("Nada a la vista.").assertExists()
    }

    @Test
    fun `a stack shows one widget at a time, swiped through, and its edit bar stacks or takes one out`() {
        store.values["vivacWidgets"] = "-1=vivac:glance:dev.vivac.launcher,-2=vivac:chats:com.termux"
        store.values["widgets"] = "-1"
        store.values["stacks"] = "-1=-2"
        show()
        compose.onNodeWithText("DE UN VISTAZO").assertIsDisplayed()
        compose.onNodeWithTag("stack:-1").performTouchInput { swipeLeft() }
        compose.waitForIdle()
        compose.onNodeWithText("TERMUX").assertIsDisplayed()
        compose.runOnUiThread { launcher.editWidget(-1) }
        compose.waitForIdle()
        compose.onNodeWithText("Sacar de la pila").performClick()
        compose.waitForIdle()
        assertEquals(listOf(-1), launcher.stackOf(-1))
        assertTrue(-2 in launcher.board.ids)
        compose.runOnUiThread { launcher.editWidget(-1) }
        compose.waitForIdle()
        compose.onNodeWithText("Apilar otro").performClick()
        compose.waitForIdle()
        assertTrue(launcher.picker != null)
    }

    @Test
    fun `a widget being edited can be removed, the one shown in a stack included`() {
        store.values["vivacWidgets"] = "-1=vivac:chats:com.termux,-2=vivac:glance:dev.vivac.launcher"
        store.values["widgets"] = "-1"
        store.values["stacks"] = "-1=-2"
        show()
        compose.onNodeWithTag("stack:-1").performTouchInput { swipeLeft() }
        compose.waitForIdle()
        compose.runOnUiThread { launcher.editWidget(-1) }
        compose.waitForIdle()
        compose.onNodeWithText("Quitar").performClick()
        compose.waitForIdle()
        assertEquals(listOf(-1), launcher.stackOf(-1))
        assertFalse(-2 in launcher.vivacWidgets)
        compose.runOnUiThread { launcher.editWidget(-1) }
        compose.waitForIdle()
        compose.onNodeWithText("Quitar").performClick()
        compose.waitForIdle()
        assertTrue(launcher.board.ids.isEmpty())
    }

    @Test
    fun `vivac's chats and shortcuts widgets show the app's chats and shortcuts in vivac's own look, and open them`() {
        actions.dotsOn = true
        actions.shortcuts = mapOf("com.termux" to listOf(AppShortcut("s", "Chat de voz")))
        store.values["vivacWidgets"] = "-1=vivac:chats:com.termux,-2=vivac:atajos:com.termux"
        store.values["widgets"] = "-1,-2"
        val notices = FakeNotices(listOf(aviso("a", "Ana")))
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets, notices = notices).also { it.refresh() }
        compose.setContent { LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, views) }
        compose.waitForIdle()
        compose.onNodeWithText("1 NUEVOS").assertExists()
        compose.onNodeWithText("texto de Ana").performClick()
        assertEquals(listOf("open:a"), notices.calls)
        compose.onNodeWithContentDescription("Chat de voz").performClick()
        assertEquals("shortcut:com.termux/s", actions.calls.last())
        // Never drawn as an app's widget view.
        assertTrue(drawn.isEmpty())
    }

    @Test
    fun `top left, the camp shows which apps have notices, and a tap opens the shade`() {
        actions.dotsOn = true
        val notices = FakeNotices(listOf(aviso("a", "Ana"), aviso("c", "Ruta", pkg = "app.organicmaps", minutesAgo = 5)))
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets, notices = notices).also { it.refresh() }
        compose.setContent { LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, views) }
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Avisos de Termux y Organic Maps").performClick()
        compose.waitForIdle()
        assertEquals(Screen.AVISOS, launcher.screen)
    }

    @Test
    fun `the camp shows the phone's signal, Wi-Fi and Tailscale, and system notices among the apps'`() {
        actions.dotsOn = true
        val system = dev.vivac.launcher.avisos.Aviso("s", "android", "USB", "Cargando", System.currentTimeMillis(), ongoing = false, clearable = true, summary = false, canReply = false, appLabel = "Sistema Android")
        val notices = FakeNotices(listOf(aviso("a", "Ana", minutesAgo = 1), system))
        launcher = Launcher(FakeSource(listOf(termux, maps, settings)), store, actions, widgets, notices = notices).also { it.refresh() }
        val status = dev.vivac.launcher.campamento.PhoneStatus(cell = 3, wifi = 2, tailscale = true)
        compose.setContent { LauncherApp(launcher, "mar 17 nov · 15:48", facts, actions, views, status = status) }
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Cobertura 3 de 4, Wi-Fi 2 de 4, Tailscale conectado").assertExists()
        compose.onNodeWithContentDescription("Avisos de Sistema Android y Termux").assertExists()
        // Drawn for real: the bars, the arcs, Tailscale's dots, the rings and the beam.
        drawWindow()
    }

    @Test
    @org.robolectric.annotation.Config(qualifiers = "w411dp-h914dp-420dpi")
    fun `a ladera's grid starts right under the top bar, so its first row is always there to use`() {
        store.values["widgets"] = "@com.termux:1,@app.organicmaps:1,@com.android.settings:1"
        show()
        compose.runOnUiThread { launcher.showPage(1) }
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
        val gear = compose.onNodeWithContentDescription("Ajustes del sistema").fetchSemanticsNode().boundsInRoot
        val tile = compose.onAllNodesWithText("Organic Maps").fetchSemanticsNodes().map { it.boundsInRoot }.first { it.left > 0 && it.top > gear.bottom }
        val dp = compose.activity.resources.displayMetrics.density
        // No dead room above the first row: less than one row between the top bar and the first tile.
        assertTrue("first row ${(tile.top - gear.bottom) / dp}dp under the bar", tile.top - gear.bottom < WidgetSizeRow * dp)
        // The free cell beside the apps in that first row takes things too.
        val free = compose.onNodeWithTag("cell:1:3").fetchSemanticsNode().boundsInRoot
        assertTrue(kotlin.math.abs(free.top - tile.top) < WidgetSizeRow * dp)
    }

    @Test
    fun `a ladera whose first row is empty shows that row as free cells at the top`() {
        store.values["widgets"] = "_:1,_:1,_:1,_:1,@com.termux:1"
        show()
        compose.runOnUiThread { launcher.showPage(1) }
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
        val gear = compose.onNodeWithContentDescription("Ajustes del sistema").fetchSemanticsNode().boundsInRoot
        val first = compose.onNodeWithTag("cell:1:0").fetchSemanticsNode().boundsInRoot
        val dp = compose.activity.resources.displayMetrics.density
        assertTrue("first cell ${(first.top - gear.bottom) / dp}dp under the bar", first.top - gear.bottom < WidgetSizeRow * dp)
    }

    @Test
    @org.robolectric.annotation.Config(qualifiers = "w914dp-h411dp-land-420dpi")
    fun `turned on its side, the camp puts the bar across the top, hour and facts left, pages in the middle and the dock down the right edge`() {
        store.values["dock"] = "com.android.settings,com.termux"
        store.values["pinned"] = "com.termux,app.organicmaps"
        show()
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
        val screen = compose.onRoot().fetchSemanticsNode().boundsInRoot
        val hour = compose.onNodeWithText("15:48").fetchSemanticsNode().boundsInRoot
        val dock = compose.onNodeWithContentDescription("Dock").fetchSemanticsNode().boundsInRoot
        val route = compose.onNodeWithTag("via").fetchSemanticsNode().boundsInRoot
        val lamp = compose.onNodeWithContentDescription("Ajustes del sistema").fetchSemanticsNode().boundsInRoot
        // The bar runs the whole width, as upright: the lamp in the top right corner, above everything else.
        assertTrue("lamp $lamp on $screen", lamp.right > screen.width * 0.9f && lamp.bottom <= route.top)
        // Hour left of the route, the dock right of it: a rail down the edge, taller than wide.
        assertTrue("hour $hour, route $route", hour.right <= route.left)
        assertTrue("dock $dock, route $route", dock.left >= route.right && dock.height > dock.width * 2)
        assertTrue("dock $dock on $screen", dock.bottom <= screen.bottom)
        // The dock's apps have room: one above the other, apart.
        val tiles = compose.onAllNodesWithContentDescription("Ajustes").fetchSemanticsNodes().map { it.boundsInRoot }.filter { it.left >= dock.left }
        val other = compose.onAllNodesWithContentDescription("Termux").fetchSemanticsNodes().map { it.boundsInRoot }.filter { it.left >= dock.left }
        assertTrue("dock tiles $tiles $other", tiles.size == 1 && other.size == 1 && other.single().top - tiles.single().bottom > 0f)
        // Names do not fit a rail: icons, and TalkBack still reads the names.
        compose.onNodeWithText("Ajustes").assertDoesNotExist()
        // The pages have most of the height to themselves.
        val dots = compose.onNode(androidx.compose.ui.test.hasContentDescription("página 1 de", substring = true)).fetchSemanticsNode().boundsInRoot
        assertTrue("dots $dots", dots.top > screen.height * 0.6f && dots.left >= hour.right)
        // Hour and facts read as one block: the facts sit right under the hour, not at the bottom of the room.
        val battery = compose.onNodeWithContentDescription("Batería al 99 %, cargando").fetchSemanticsNode().boundsInRoot
        val dp = compose.activity.resources.displayMetrics.density
        assertTrue("hour $hour, battery $battery", battery.top - hour.bottom < 48 * dp)
    }

    @Test
    @org.robolectric.annotation.Config(qualifiers = "w914dp-h411dp-land-420dpi")
    fun `turned on its side, a swipe across the pages goes to the next ladera and its apps show whole`() {
        store.values["widgets"] = "@com.termux:1,@app.organicmaps:1"
        store.values["pinned"] = "com.android.settings"
        show()
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
        val via = compose.onNodeWithTag("via").fetchSemanticsNode().boundsInRoot
        compose.onRoot().performTouchInput { swipe(Offset(via.right - 40f, via.center.y), Offset(via.left + 40f, via.center.y), 250) }
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
        assertEquals(1, launcher.page)
        val screen = compose.onRoot().fetchSemanticsNode().boundsInRoot
        val tile = compose.onAllNodesWithText("Organic Maps").fetchSemanticsNodes().map { it.boundsInRoot }.first { it.left > via.left - 40f }
        assertTrue("tile $tile on $screen", tile.top >= 0f && tile.bottom <= screen.bottom)
    }

    private val WidgetSizeRow = dev.vivac.launcher.campamento.WidgetSize.ROW_DP.toFloat()
}
