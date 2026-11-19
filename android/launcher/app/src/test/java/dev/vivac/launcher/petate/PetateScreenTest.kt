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
import androidx.compose.ui.test.performTextClearance
import org.junit.Assert.assertTrue
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.swipeDown
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.apps.InstalledApp
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import dev.vivac.launcher.core.CalendarEvent
import dev.vivac.launcher.core.Contact
import androidx.compose.ui.test.performScrollTo
import dev.vivac.launcher.apps.Profile
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
        compose.onNodeWithText("Ocultas · 1").performScrollTo().performClick()
        compose.onNodeWithText("Organic Maps").assertExists()
        compose.onNodeWithText("Termux").assertDoesNotExist()
    }

    @Test
    fun `when hidden apps are protected, the Ocultas chip shows them only after you prove it is you`() {
        var allow = false
        var asked = 0
        compose.setContent {
            PetateScreen(
                listOf(termux, maps, settings), setOf("app.organicmaps"), focusSearch = false, onOpenApp = {}, onAppMenu = {},
                askToSeeHidden = { ok -> asked++; if (allow) ok() },
            )
        }
        compose.onNodeWithText("Ocultas · 1").performScrollTo().performClick()
        compose.onNodeWithText("Organic Maps").assertDoesNotExist()
        allow = true
        compose.onNodeWithText("Ocultas · 1").performScrollTo().performClick()
        compose.onNodeWithText("Organic Maps").assertExists()
        // Closing them again asks for nothing.
        compose.onNodeWithText("Ocultas · 1").performScrollTo().performClick()
        compose.onNodeWithText("Organic Maps").assertDoesNotExist()
        assertEquals(2, asked)
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

    @Test
    fun `a search lists Android's settings pages it matches, and a tap opens one`() {
        val pages = mutableListOf<dev.vivac.launcher.core.SystemPage>()
        compose.setContent {
            PetateScreen(listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {}, onOpenSettingsPage = { pages += it })
        }
        compose.onNodeWithText("AJUSTES DE ANDROID").assertDoesNotExist()
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("brillo")
        compose.onNodeWithText("AJUSTES DE ANDROID").assertExists()
        // Something was found, just not an app: no "nothing here".
        compose.onNodeWithText("Nada en el petate con «brillo».").assertDoesNotExist()
        compose.onNodeWithText("Pantalla").performClick()
        assertEquals(listOf(dev.vivac.launcher.core.SystemPage.PANTALLA), pages)
    }

    @Test
    fun `the petate is a bag with its own label and no filler text`() {
        show()
        compose.onNodeWithText("Petate").assertExists()
        compose.onNodeWithText("Busca en el petate").assertExists()
        listOf("PETATE · MATERIAL", "BUSCAR · NOMBRE O INICIALES", "Organic Maps → om", "control del campamento", "lo de cada día", "grapheneos").forEach {
            compose.onNodeWithText(it).assertDoesNotExist()
        }
        compose.onNodeWithText("DE GOOGLE", substring = true).assertDoesNotExist()
    }

    @Test
    fun `what you open from a search is remembered, and past searches come back with a tap`() {
        val searched = mutableListOf<String>()
        var cleared = false
        compose.setContent {
            PetateScreen(
                listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {},
                searches = listOf("wifi"), onSearched = { searched += it }, onClearSearches = { cleared = true },
            )
        }
        // Past searches wait inside the mouth of the bag: they show once you reach for the search.
        compose.onNodeWithText("BÚSQUEDAS").assertDoesNotExist()
        compose.onNodeWithContentDescription("Buscar en el petate").performClick()
        compose.onNodeWithText("BÚSQUEDAS").assertExists()
        compose.onNodeWithText("wifi").performClick()
        compose.onNodeWithText("AJUSTES DE ANDROID").assertExists()
        compose.onNodeWithText("Wi-Fi").performClick()
        assertEquals(listOf("wifi"), searched)
        compose.onNodeWithContentDescription("Buscar en el petate").performTextClearance()
        compose.onNodeWithText("Borrar").performClick()
        assertTrue(cleared)
    }

    @Test
    fun `category chips show only the apps of that category, and a second tap shows all again`() {
        compose.setContent {
            PetateScreen(listOf(termux, maps.copy(category = "Mapas"), settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {})
        }
        compose.onNodeWithText("Mapas").performScrollTo().performClick()
        compose.onNodeWithText("Organic Maps").assertExists()
        compose.onNodeWithText("Termux").assertDoesNotExist()
        compose.onNodeWithText("Mapas").performScrollTo().performClick()
        compose.onNodeWithText("Termux").assertExists()
    }

    @Test
    fun `a search lists the photos, videos and music it matches, and a tap opens one`() {
        val opened = mutableListOf<dev.vivac.launcher.core.FoundFile>()
        val photo = dev.vivac.launcher.core.FoundFile(9, "playa.jpg", dev.vivac.launcher.core.FoundFile.Kind.FOTO)
        compose.setContent {
            PetateScreen(
                listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {},
                findFiles = { q -> if ("playa".startsWith(q)) listOf(photo) else emptyList() }, onOpenFile = { opened += it },
                io = kotlinx.coroutines.Dispatchers.Unconfined,
            )
        }
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("playa")
        compose.waitForIdle()
        compose.onNodeWithText("ARCHIVOS").assertExists()
        compose.onNodeWithText("playa.jpg").performClick()
        assertEquals(listOf(photo), opened)
    }

    @Test
    fun `a search lists the shortcuts it matches, and a tap opens one`() {
        val opened = mutableListOf<FoundShortcut>()
        val chat = FoundShortcut(maps, AppShortcut("home", "Ir a casa"))
        compose.setContent {
            PetateScreen(listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {}, shortcuts = listOf(chat), onOpenShortcut = { opened += it })
        }
        compose.onNodeWithText("ATAJOS").assertDoesNotExist()
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("casa")
        compose.onNodeWithText("Ir a casa").performClick()
        assertEquals(listOf(chat), opened)
    }

    @Test
    fun `the work profile and private space have their own chips, open their apps there, and lock`() {
        val asked = mutableListOf<String>()
        val work = Profile(10, Profile.Kind.WORK, locked = false, apps = listOf(InstalledApp("Slack", "com.slack", false)))
        val private = Profile(11, Profile.Kind.PRIVATE, locked = true, apps = emptyList())
        compose.setContent {
            PetateScreen(
                listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = { asked += "main:$it" }, onAppMenu = { asked += "menu:$it" },
                profiles = listOf(work, private),
                onOpenInProfile = { pkg, id -> asked += "open:$id:$pkg" },
                onLockProfile = { asked += "lock:${it.id}" },
            )
        }
        compose.onNodeWithText("Trabajo").performScrollTo().performClick()
        compose.onNodeWithText("Termux").assertDoesNotExist()
        compose.onNodeWithText("Perfil de trabajo · 1 apps").assertExists()
        compose.onNodeWithText("Slack").performClick()
        compose.onNodeWithText("Slack").performTouchInput { longClick() }
        compose.onNodeWithText("Pausar").performClick()
        compose.onNodeWithText("Privado").performScrollTo().performClick()
        compose.onNodeWithText("Espacio privado bloqueado: desbloquéalo para ver sus apps.").assertExists()
        compose.onNodeWithText("Desbloquear").performClick()
        compose.onNodeWithText("Todo").performScrollTo().performClick()
        compose.onNodeWithText("Termux").assertExists()
        assertEquals(listOf("open:10:com.slack", "lock:10", "lock:11"), asked)
    }

    @Test
    fun `a paused work profile and an open private space say so`() {
        compose.setContent {
            PetateScreen(
                listOf(termux), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {},
                profiles = listOf(
                    Profile(10, Profile.Kind.WORK, locked = true, apps = emptyList()),
                    Profile(11, Profile.Kind.PRIVATE, locked = false, apps = listOf(InstalledApp("Banco", "a.bank", false))),
                ),
            )
        }
        compose.onNodeWithText("Trabajo").performScrollTo().performClick()
        compose.onNodeWithText("Reanudar").assertExists()
        compose.onNodeWithText("Privado").performScrollTo().performClick()
        compose.onNodeWithText("Espacio privado abierto · 1 apps").assertExists()
        compose.onNodeWithText("Bloquear").assertExists()
    }

    @Test
    fun `a search lists matching contacts and events, and a tap opens one`() {
        val opened = mutableListOf<String>()
        val ana = Contact(1, "Ana García", "a")
        val dinner = CalendarEvent(5, "Cena con Ana", java.time.ZonedDateTime.of(2026, 11, 21, 20, 30, 0, 0, java.time.ZoneId.systemDefault()).toInstant().toEpochMilli())
        compose.setContent {
            PetateScreen(
                listOf(termux, maps, settings), emptySet(), focusSearch = false, onOpenApp = {}, onAppMenu = {},
                findContacts = { q -> if (q.isNotBlank()) listOf(ana) else emptyList() },
                findEvents = { q -> if (q.isNotBlank()) listOf(dinner) else emptyList() },
                onOpenContact = { opened += "contact:${it.id}" },
                onOpenEvent = { opened += "event:${it.id}" },
                io = kotlinx.coroutines.Dispatchers.Unconfined,
            )
        }
        compose.onNodeWithText("CONTACTOS").assertDoesNotExist()
        compose.onNodeWithContentDescription("Buscar en el petate").performTextInput("ana")
        compose.waitForIdle()
        compose.onNodeWithText("Ana García").performClick()
        compose.onNodeWithText("sáb 21 nov · 20:30").assertExists()
        compose.onNodeWithText("Cena con Ana").performClick()
        assertEquals(listOf("contact:1", "event:5"), opened)
    }
}
