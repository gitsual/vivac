package dev.vivac.launcher.petate

import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.swipeDown
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.apps.InstalledApp
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PetateScreenTest {
    @get:Rule val compose = createComposeRule()

    private val termux = InstalledApp("Termux", "com.termux", false)
    private val maps = InstalledApp("Organic Maps", "app.organicmaps", false)
    private val settings = InstalledApp("Ajustes", "com.android.settings", true)
    private val opened = mutableListOf<String>()
    private val menus = mutableListOf<String>()

    private fun show(hidden: Set<String> = emptySet()) = compose.setContent {
        PetateScreen(listOf(termux, maps, settings), hidden, focusSearch = false, onOpenApp = { opened += it }, onAppMenu = { menus += it })
    }

    @Test
    fun `tapping a tile opens the app and a long press opens its menu`() {
        show()
        compose.onNodeWithText("Organic Maps").performClick()
        compose.onNodeWithText("Termux").performTouchInput { longClick() }
        assertEquals(listOf("app.organicmaps"), opened)
        assertEquals(listOf("com.termux"), menus)
    }

    @Test
    fun `search narrows the shelves and Go opens the only match`() {
        show()
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("organic")
        compose.onNodeWithText("Termux").assertDoesNotExist()
        compose.onNodeWithContentDescription("Buscar en el petate").performImeAction()
        assertEquals(listOf("app.organicmaps"), opened)
    }

    @Test
    fun `a search with no match says so`() {
        show()
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("zzz")
        compose.onNodeWithText("Nada en el petate con «zzz».").assertExists()
    }

    @Test
    fun `a group chip keeps only its shelf`() {
        show()
        val chip = compose.onNode(hasText("Sistema") and SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab))
        chip.performClick()
        chip.assertIsSelected()
        compose.onNodeWithText("Ajustes").assertExists()
        compose.onNodeWithText("Organic Maps").assertDoesNotExist()
    }

    @Test
    fun `hidden apps only show behind the Ocultas chip`() {
        show(hidden = setOf("app.organicmaps"))
        compose.onNodeWithText("Organic Maps").assertDoesNotExist()
        compose.onNodeWithText("Ocultas · 1").performClick()
        compose.onNodeWithText("Organic Maps").assertExists()
        compose.onNodeWithText("Termux").assertDoesNotExist()
    }

    @Test
    fun `the altimeter jumps to a letter far down the list, and only letters with apps are buttons`() {
        val many = ('A'..'Z').flatMap { c -> (1..3).map { InstalledApp("$c-app $it", "p.$c$it", false) } }
        compose.setContent { PetateScreen(many, emptySet(), focusSearch = false, onOpenApp = { opened += it }, onAppMenu = {}) }
        compose.onNodeWithText("Z-app 1").assertIsNotDisplayed()
        compose.onNodeWithContentDescription("Saltar a la Z").performClick()
        compose.onNodeWithText("Z-app 1").assertIsDisplayed()
        compose.onNodeWithContentDescription("Saltar a la #").assertDoesNotExist()
    }

    @Test
    fun `the last pitch shows what you opened lately, and opens it`() {
        compose.setContent {
            PetateScreen(listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = { opened += it }, onAppMenu = {}, recent = listOf(maps))
        }
        compose.onNodeWithText("ÚLTIMO LARGO").assertExists()
        compose.onAllNodesWithText("Organic Maps").assertCountEquals(2)
        compose.onAllNodesWithText("Organic Maps")[0].performClick()
        assertEquals(listOf("app.organicmaps"), opened)
    }

    @Test
    fun `the last pitch steps aside while you search`() {
        compose.setContent {
            PetateScreen(listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {}, recent = listOf(maps))
        }
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("om")
        compose.onNodeWithText("ÚLTIMO LARGO").assertDoesNotExist()
        compose.onNodeWithText("Termux").assertDoesNotExist()
    }

    @Test
    fun `sliding along the altimeter jumps too`() {
        val many = ('A'..'Z').flatMap { c -> (1..3).map { InstalledApp("$c-app $it", "p.$c$it", false) } }
        compose.setContent { PetateScreen(many, emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {}) }
        compose.onNodeWithContentDescription("Altímetro: desliza para saltar de letra").performTouchInput { swipeDown() }
        compose.onNodeWithText("Z-app 1").assertIsDisplayed()
    }

    @Test
    fun `a sum or a conversion in the search shows its answer, and tapping it copies it`() {
        val copied = mutableListOf<String>()
        compose.setContent {
            PetateScreen(listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {}, onCopy = { copied += it })
        }
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("5 km en mi")
        compose.onNodeWithText("3,10686 mi").assertExists()
        compose.onNodeWithContentDescription("Copiar 3,10686 mi").performClick()
        assertEquals(listOf("3,10686 mi"), copied)
        compose.onNodeWithText("Nada en el petate con «5 km en mi».").assertDoesNotExist()
    }

    @Test
    fun `a search can go on to the web or the app store`() {
        val asked = mutableListOf<String>()
        compose.setContent {
            PetateScreen(
                listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {},
                onWebSearch = { asked += "web:$it" }, onStoreSearch = { asked += "store:$it" },
            )
        }
        compose.onNodeWithText("Buscar en la web").assertDoesNotExist()
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("mapas")
        compose.onNodeWithText("Buscar en la web").performClick()
        compose.onNodeWithText("Buscar en la tienda").performClick()
        assertEquals(listOf("web:mapas", "store:mapas"), asked)
    }
}
