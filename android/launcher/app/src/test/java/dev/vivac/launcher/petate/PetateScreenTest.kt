package dev.vivac.launcher.petate

import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.longClick
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
}
