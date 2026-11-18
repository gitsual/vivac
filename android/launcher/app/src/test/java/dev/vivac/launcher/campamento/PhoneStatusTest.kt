package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneStatusTest {
    @Test
    fun `a VPN with an address in Tailscale's range is Tailscale`() {
        assertTrue(PhoneStatus.isTailscale(listOf("100.73.224.90")))
        assertTrue(PhoneStatus.isTailscale(listOf("fe80::1", "100.64.0.1")))
        assertTrue(PhoneStatus.isTailscale(listOf("100.127.255.254")))
        assertFalse(PhoneStatus.isTailscale(listOf("100.128.0.1")))
        assertFalse(PhoneStatus.isTailscale(listOf("10.2.0.2")))
        assertFalse(PhoneStatus.isTailscale(emptyList()))
    }

    @Test
    fun `a signal is told in four bars`() {
        assertEquals(0, PhoneStatus.bars(level = 0, max = 4))
        assertEquals(4, PhoneStatus.bars(level = 4, max = 4))
        assertEquals(2, PhoneStatus.bars(level = 2, max = 4))
        // Some phones count Wi-Fi in five steps (0..4) or more: scaled to four bars.
        assertEquals(4, PhoneStatus.bars(level = 5, max = 5))
        assertEquals(2, PhoneStatus.bars(level = 3, max = 6))
    }

    @Test
    fun `how the status reads aloud`() {
        assertEquals(
            "Cobertura 3 de 4, Wi-Fi 2 de 4, Tailscale conectado",
            PhoneStatus(cell = 3, wifi = 2, tailscale = true).spoken,
        )
        assertEquals("Sin cobertura, sin Wi-Fi", PhoneStatus(cell = null, wifi = null, tailscale = false).spoken)
    }
}
