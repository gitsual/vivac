package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDateTime

class CampTest {
    @Test
    fun `stamp is short lowercase Spanish without abbreviation dots`() {
        assertEquals("lun 16 nov · 22:49", Stamp.format(LocalDateTime.of(2026, 11, 16, 22, 49)))
        assertEquals("sáb 3 ene · 07:05", Stamp.format(LocalDateTime.of(2026, 1, 3, 7, 5)))
        assertEquals("mié 9 sept · 00:00", Stamp.format(LocalDateTime.of(2026, 9, 9, 0, 0)))
    }

    @Test
    fun `security patch reads as a Spanish date, or stays raw when it is not one`() {
        assertEquals("5 nov 2026", PhoneFacts.patchLabel("2026-11-05"))
        assertEquals("desconocido", PhoneFacts.patchLabel("desconocido"))
    }

    @Test
    fun `dock takes the first four installed favourites, then the Petate`() {
        val installed = setOf("com.whatsapp", "com.termux", "app.vanadium.browser", "com.tailscale.ipn", "org.telegram.messenger")
        assertEquals(
            listOf(
                DockSlot.App("com.termux"),
                DockSlot.App("com.whatsapp"),
                DockSlot.App("app.vanadium.browser"),
                DockSlot.App("com.tailscale.ipn"),
                DockSlot.Petate,
            ),
            Dock.pick(installed),
        )
    }

    @Test
    fun `signal wins over whatsapp when both are there, and missing apps are skipped`() {
        val installed = setOf("org.thoughtcrime.securesms", "com.whatsapp")
        assertEquals(
            listOf(DockSlot.App("org.thoughtcrime.securesms"), DockSlot.App("com.whatsapp"), DockSlot.Petate),
            Dock.pick(installed),
        )
    }
}
