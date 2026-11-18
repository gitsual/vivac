package dev.vivac.launcher.core

import dev.vivac.launcher.campamento.Placed
import dev.vivac.launcher.campamento.Shelved
import dev.vivac.launcher.campamento.WidgetBoard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupTest {
    @Test
    fun `a copy carries the layout and your choices, but not widget ids, which belong to this phone`() {
        val from = FakeStore(mutableMapOf(
            "dock" to "a,b", "pinned" to "c", "hidden" to "", "names" to "c=Mapas%2C+offline",
            "widgets" to "4:0:2,@c:1,#c|home|Casa:1", "locked" to "1", "pendingWidget" to "9",
        ))
        val text = Backup.export(from)
        assertTrue(text.startsWith("vivac-campamento 1\n"))
        val to = FakeStore(mutableMapOf("widgets" to "7:0:0", "dock" to "z"))
        assertTrue(Backup.restore(text, to))
        assertEquals("a,b", to.values["dock"])
        assertEquals("c=Mapas%2C+offline", to.values["names"])
        assertEquals("1", to.values["locked"])
        assertEquals(null, to.values["pendingWidget"])
        val board = WidgetBoard.decode(to.values["widgets"])
        assertEquals(listOf(7), board.ids)
        assertTrue(Shelved("c", 1) in board.items)
        assertFalse(board.items.any { it is Placed && it.id == 4 })
    }

    @Test
    fun `anything that is not a vivac copy is refused and changes nothing`() {
        val to = FakeStore(mutableMapOf("dock" to "z"))
        assertFalse(Backup.restore("hola", to))
        assertFalse(Backup.restore("", to))
        assertEquals(mapOf("dock" to "z"), to.values)
        assertTrue(Backup.restore("vivac-campamento 1\nnope\nunknown=x\ndock=q", to))
        assertEquals(mapOf("dock" to "q"), to.values)
    }
}
