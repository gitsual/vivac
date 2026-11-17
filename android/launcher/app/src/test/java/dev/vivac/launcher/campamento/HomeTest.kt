package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HomeTest {
    @Test
    fun `adding to the dock appends, removing takes it out`() {
        val home = Home().toggleDock("a").home!!.toggleDock("b").home!!
        assertEquals(listOf("a", "b"), home.dock)
        assertEquals(listOf("b"), home.toggleDock("a").home!!.dock)
    }

    @Test
    fun `the dock holds four apps, a fifth is refused`() {
        val full = Home(dock = listOf("a", "b", "c", "d"))
        val change = full.toggleDock("e")
        assertNull(change.home)
        assertEquals("El dock ya tiene 4 apps: quita una primero.", change.refusal)
    }

    @Test
    fun `the campamento pins up to eight apps`() {
        val full = Home(pinned = (1..8).map { "p$it" })
        assertEquals("El campamento ya tiene 8 apps a mano: quita una primero.", full.togglePin("x").refusal)
        assertEquals((2..8).map { "p$it" }, full.togglePin("p1").home!!.pinned)
    }

    @Test
    fun `uninstalled apps drop out of dock and pins`() {
        val home = Home(dock = listOf("a", "gone"), pinned = listOf("gone", "b"))
        assertEquals(Home(dock = listOf("a"), pinned = listOf("b")), home.keepOnly(setOf("a", "b")))
    }

    @Test
    fun `it survives a round trip through storage, empty lists included`() {
        val home = Home(dock = listOf("com.termux", "com.whatsapp"), pinned = emptyList())
        assertEquals(home, Home.decode(home.encodeDock(), home.encodePinned()))
        assertEquals(Home(), Home.decode(null, ""))
    }

    @Test
    fun `a dock you chose replaces the default favourites`() {
        val installed = setOf("com.termux", "com.whatsapp", "app.organicmaps")
        assertEquals(
            listOf(DockSlot.App("app.organicmaps"), DockSlot.App("com.termux"), DockSlot.Petate),
            Dock.pick(installed, chosen = listOf("app.organicmaps", "not.installed", "com.termux")),
        )
    }
}
