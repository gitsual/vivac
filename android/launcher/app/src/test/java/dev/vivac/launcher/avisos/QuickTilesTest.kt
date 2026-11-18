package dev.vivac.launcher.avisos

import org.junit.Assert.assertEquals
import org.junit.Test

class QuickTilesTest {
    private val wifi = Quick.Of(Control.WIFI)
    private val torch = Quick.Of(Control.LINTERNA)
    private val tailscale = Quick.App("com.tailscale.ipn")

    @Test
    fun `by default the shade has the phone's own switches, in its order, then Tailscale and vivac's three`() {
        val ids = QuickTiles.DEFAULT.map { (it as? Quick.Of)?.control?.id ?: "app" }
        assertEquals(
            listOf("wifi", "bt", "cell", "airplane", "dnd", "flashlight", "rotation", "alarm", "screenrecord", "battery", "mictoggle", "cameratoggle", "location", "cast", "hotspot", "app", "volume", "settings", "android"),
            ids,
        )
    }

    @Test
    fun `switches are added once, taken out, and moved one place at a time within the ends`() {
        val list = listOf(wifi, torch)
        assertEquals(list, QuickTiles.add(list, torch))
        assertEquals(list + tailscale, QuickTiles.add(list, tailscale))
        assertEquals(listOf(torch), QuickTiles.remove(list, wifi))
        assertEquals(listOf(torch, wifi), QuickTiles.move(list, wifi, +1))
        assertEquals(list, QuickTiles.move(list, wifi, -1))
        assertEquals(list, QuickTiles.move(list, tailscale, +1))
    }

    @Test
    fun `what can be added is every switch not in the shade yet`() {
        val available = QuickTiles.available(QuickTiles.DEFAULT)
        assertEquals(listOf(Control.NFC, Control.TEMA, Control.LUZ), available)
    }

    @Test
    fun `the list is kept as ids, unknown ones dropped, nothing kept means the default`() {
        val list = listOf(torch, tailscale, wifi)
        assertEquals("flashlight,app:com.tailscale.ipn,wifi", QuickTiles.encode(list))
        assertEquals(list, QuickTiles.decode("flashlight,app:com.tailscale.ipn,wifi,nope,app:"))
        assertEquals(QuickTiles.DEFAULT, QuickTiles.decode(null))
        assertEquals(emptyList<Quick>(), QuickTiles.decode(""))
    }

    @Test
    fun `in two rows that scroll sideways, each page of eight reads row by row, a short last page padded`() {
        val tiles = (1..10).map { Quick.App("p$it") }
        // Laid out column by column (two to a column), so the screen shows p1 p2 p3 p4 over p5 p6 p7 p8.
        assertEquals(
            listOf("p1", "p5", "p2", "p6", "p3", "p7", "p4", "p8", "p9", null, "p10", null),
            QuickTiles.columns(tiles).map { (it as Quick.App?)?.packageName },
        )
    }
}
