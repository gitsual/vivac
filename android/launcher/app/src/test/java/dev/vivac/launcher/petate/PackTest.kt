package dev.vivac.launcher.petate

import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.core.SystemPage as SP
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PackTest {
    private fun app(label: String, pkg: String, system: Boolean = false) = InstalledApp(label, pkg, system)

    private val termux = app("Termux", "com.termux")
    private val tailscale = app("Tailscale", "com.tailscale.ipn")
    private val whatsapp = app("WhatsApp", "com.whatsapp")
    private val maps = app("Organic Maps", "app.organicmaps")
    private val settings = app("Ajustes", "com.android.settings", system = true)
    private val gmail = app("Gmail", "com.google.android.gm")
    private val play = app("Play Store", "com.android.vending", system = true)

    @Test
    fun `infra apps go to Infra even when they are system apps`() {
        assertEquals(Group.INFRA, Pack.groupOf(termux))
        assertEquals(Group.INFRA, Pack.groupOf(tailscale))
        assertEquals(Group.INFRA, Pack.groupOf(app("vivac", "dev.vivac.launcher", system = true)))
    }

    @Test
    fun `system apps go to Sistema and the rest to Dia a dia`() {
        assertEquals(Group.SYSTEM, Pack.groupOf(settings))
        assertEquals(Group.DAILY, Pack.groupOf(whatsapp))
    }

    @Test
    fun `grapheneos apps are Sistema even when updated from its store`() {
        assertEquals(Group.SYSTEM, Pack.groupOf(app("Cámara", "app.grapheneos.camera")))
        assertEquals(Group.SYSTEM, Pack.groupOf(app("Auditor", "app.attestation.auditor")))
        assertEquals(Group.SYSTEM, Pack.groupOf(app("Vanadium", "app.vanadium.browser")))
    }

    @Test
    fun `monogram follows words, then inner capitals, then the first two letters`() {
        assertEquals("Om", Pack.monogram(maps))
        assertEquals("Ls", Pack.monogram(app("LocalSend", "org.localsend.localsend_app")))
        assertEquals("Kp", Pack.monogram(app("KeePassDX", "com.kunzisoft.keepass.libre")))
        assertEquals("Si", Pack.monogram(app("Signal", "org.thoughtcrime.securesms")))
        assertEquals("Wa", Pack.monogram(whatsapp))
        assertEquals("Ta", Pack.monogram(app("Termux:API", "com.termux.api")))
    }

    @Test
    fun `termux keeps its prompt as monogram`() {
        assertEquals(">_", Pack.monogram(termux))
    }

    @Test
    fun `monogram survives short and symbol-led labels`() {
        assertEquals("X", Pack.monogram(app("X", "com.twitter.android")))
        assertEquals("Cá", Pack.monogram(app("  Cámara", "app.grapheneos.camera")))
        assertEquals("?", Pack.monogram(app("", "a.b")))
    }

    @Test
    fun `search ignores case and accents`() {
        val camera = app("Cámara", "app.grapheneos.camera", system = true)
        assertEquals(listOf(camera), Pack.search(listOf(camera, whatsapp), "CAMA"))
        assertEquals(listOf(camera, whatsapp), Pack.search(listOf(camera, whatsapp), "  "))
    }

    @Test
    fun `search also matches initials, from words and inner capitals`() {
        val keepass = app("KeePassDX", "com.kunzisoft.keepass.libre")
        val localsend = app("LocalSend", "org.localsend.localsend_app")
        val apps = listOf(maps, keepass, localsend, whatsapp)
        assertEquals(listOf(maps), Pack.search(apps, "om"))
        assertEquals(listOf(keepass), Pack.search(apps, "KP"))
        assertEquals(listOf(localsend), Pack.search(apps, "ls"))
    }

    @Test
    fun `every app files under one altimeter letter, accents folded, the rest under hash`() {
        assertEquals('C', Pack.initialOf(app("Cámara", "a.c")))
        assertEquals('O', Pack.initialOf(maps))
        assertEquals('#', Pack.initialOf(app("1Password", "a.p")))
        assertEquals('#', Pack.initialOf(app("", "a.e")))
    }

    @Test
    fun `the altimeter jumps to the first app of each letter, counting the shelf headers`() {
        val angel = app("Ángel", "a.a")
        val zeta = app("Zeta", "z.z")
        val shelves = Pack.grouped(listOf(termux, angel, zeta, whatsapp, settings), filter = null)
        // Items: [Infra header, Termux, Día a día header, Ángel, WhatsApp, Zeta, Sistema header, Ajustes]
        assertEquals(mapOf('T' to 1, 'A' to 3, 'W' to 4, 'Z' to 5), Pack.jumps(shelves))
    }

    @Test
    fun `groups come in fixed order, sorted the Spanish way, empty ones dropped`() {
        val zeta = app("Zeta", "z.z")
        val angel = app("Ángel", "a.a")
        val grouped = Pack.grouped(listOf(zeta, settings, angel, termux), filter = null)
        assertEquals(listOf(Group.INFRA, Group.DAILY, Group.SYSTEM), grouped.map { it.first })
        assertEquals(listOf(angel, zeta), grouped[1].second)
    }

    @Test
    fun `a chip filter keeps only its group`() {
        val grouped = Pack.grouped(listOf(whatsapp, settings, termux), filter = Group.SYSTEM)
        assertEquals(listOf(Group.SYSTEM to listOf(settings)), grouped)
    }

    @Test
    fun `summary counts apps and the Google ones honestly`() {
        assertEquals("4 apps · 2 de Google", Pack.summary(listOf(termux, whatsapp, gmail, play)))
        assertEquals("1 app · 0 de Google", Pack.summary(listOf(termux)))
    }

    @Test
    fun `tone is stable per package and within the palette`() {
        val a = Pack.toneIndex(whatsapp, 6)
        assertEquals(a, Pack.toneIndex(whatsapp.copy(label = "otro"), 6))
        assertTrue(a in 0 until 6)
    }

    @Test
    fun `hidden apps leave the shelves, and only they show when asking for them`() {
        val apps = listOf(termux, whatsapp, settings)
        assertEquals(listOf(termux, settings), Pack.visible(apps, hidden = setOf("com.whatsapp"), showHidden = false))
        assertEquals(listOf(whatsapp), Pack.visible(apps, hidden = setOf("com.whatsapp"), showHidden = true))
    }

    @Test
    fun `a slip of the finger still finds the app, exact matches first, short words must be exact`() {
        val all = listOf(termux, tailscale, whatsapp, maps, settings)
        assertEquals(listOf(tailscale), Pack.search(all, "tialscale"))
        assertEquals(listOf(maps), Pack.search(all, "organci"))
        assertEquals(listOf(whatsapp), Pack.search(all, "whatsap"))
        assertEquals(listOf(termux), Pack.search(all, "trmux"))
        assertEquals(emptyList<InstalledApp>(), Pack.search(all, "tmx"))
        assertEquals(listOf(maps), Pack.search(all, "maps"))
        assertEquals(emptyList<InstalledApp>(), Pack.search(all, "mapz"))
        // A real match beats a near one: "termux" does not drag in anything that is one letter off.
        assertEquals(listOf(termux), Pack.search(listOf(tailscale, termux), "termux"))
    }

    @Test
    fun `shortcuts are found by their own name, never with an empty search`() {
        val chat = FoundShortcut(whatsapp, AppShortcut("new", "Nuevo chat"))
        val camera = FoundShortcut(whatsapp, AppShortcut("cam", "Cámara"))
        assertEquals(listOf(chat), Pack.searchShortcuts(listOf(chat, camera), "chat"))
        assertEquals(listOf(camera), Pack.searchShortcuts(listOf(chat, camera), "camara"))
        assertEquals(emptyList<FoundShortcut>(), Pack.searchShortcuts(listOf(chat, camera), " "))
    }

    @Test
    fun `settings pages are found by name or by what they hold, names first, ignoring accents and dashes`() {
        assertEquals(SP.WIFI, Pack.searchSettings("wifi").first())
        assertTrue(SP.INTERNET in Pack.searchSettings("wifi"))
        assertEquals(listOf(SP.BATERIA, SP.AHORRO), Pack.searchSettings("bateria").take(2))
        assertTrue(SP.PANTALLA in Pack.searchSettings("brillo"))
        assertEquals(emptyList<Any>(), Pack.searchSettings("  "))
        assertEquals(emptyList<Any>(), Pack.searchSettings("qzx"))
        assertTrue(Pack.searchSettings("a").size <= 4)
    }

    @Test
    fun `android's app categories get spanish names, and the petate lists the ones present, sorted`() {
        assertEquals("Juegos", Pack.androidCategory(0))
        assertEquals("Mapas", Pack.androidCategory(6))
        assertEquals("Accesibilidad", Pack.androidCategory(8))
        assertEquals(null, Pack.androidCategory(-1))
        assertEquals(null, Pack.androidCategory(99))
        val apps = listOf(maps.copy(category = "Mapas"), termux, gmail.copy(category = "Productividad"), whatsapp.copy(category = "Social"), tailscale.copy(category = "mapas"))
        assertEquals(listOf("Mapas", "Productividad", "Social"), Pack.categories(apps))
    }
}
