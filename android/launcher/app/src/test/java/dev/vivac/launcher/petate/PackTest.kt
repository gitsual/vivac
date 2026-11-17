package dev.vivac.launcher.petate

import dev.vivac.launcher.apps.InstalledApp
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
}
