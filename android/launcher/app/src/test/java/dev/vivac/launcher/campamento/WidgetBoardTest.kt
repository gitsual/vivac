package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Test

class WidgetBoardTest {
    private fun board(vararg placed: Placed) = WidgetBoard(placed.toList())

    @Test
    fun `widgets are added to the camp in order and removed by id`() {
        val b = WidgetBoard().add(7).add(12).add(3)
        assertEquals(listOf(7, 12, 3), b.ids)
        assertEquals(listOf(7, 3), b.remove(12).ids)
        assertEquals(listOf(Placed(7), Placed(12), Placed(3)), b.onPage(0))
    }

    @Test
    fun `adding the same id twice keeps one`() {
        assertEquals(listOf(5), WidgetBoard().add(5).add(5).ids)
    }

    @Test
    fun `the camp is always there, and every ladera with a widget after it`() {
        assertEquals(1, WidgetBoard().pages)
        assertEquals(3, board(Placed(1), Placed(2, page = 2), Placed(3, page = 1)).pages)
    }

    @Test
    fun `moving a widget sends it to the end of that page, and a new page opens past the last`() {
        val b = board(Placed(1), Placed(2), Placed(3, page = 1))
        assertEquals(listOf(Placed(3, page = 1), Placed(1, page = 1)), b.moveTo(1, page = 1).onPage(1))
        val opened = b.moveTo(2, page = b.pages)
        assertEquals(3, opened.pages)
        assertEquals(listOf(Placed(2, page = 2)), opened.onPage(2))
    }

    @Test
    fun `an emptied ladera closes and the ones after it move down, the camp never closes`() {
        val b = board(Placed(1), Placed(2, page = 1), Placed(3, page = 2))
        val closed = b.moveTo(2, page = 0)
        assertEquals(2, closed.pages)
        assertEquals(listOf(Placed(3, page = 1)), closed.onPage(1))
        assertEquals(1, board(Placed(1, page = 1)).moveTo(1, page = 0).pages)
        assertEquals(1, board(Placed(1)).remove(1).pages)
    }

    @Test
    fun `a widget moves earlier or later within its page, stopping at the ends`() {
        val b = board(Placed(1), Placed(9, page = 1), Placed(2), Placed(3))
        assertEquals(listOf(1, 3, 2), b.shift(3, -1).onPage(0).map { (it as Placed).id })
        assertEquals(listOf(2, 1, 3), b.shift(1, +1).onPage(0).map { (it as Placed).id })
        assertEquals(listOf(1, 2, 3), b.shift(1, -1).onPage(0).map { (it as Placed).id })
        assertEquals(listOf(1, 2, 3), b.shift(3, +1).onPage(0).map { (it as Placed).id })
    }

    @Test
    fun `apps go on a ladera, once each, after what is already there`() {
        val b = board(Placed(1, page = 1)).addApp("com.whatsapp", page = 1).addApp("org.telegram", page = 1).addApp("com.whatsapp", page = 1)
        assertEquals(listOf(Placed(1, page = 1), Shelved("com.whatsapp", 1), Shelved("org.telegram", 1)), b.onPage(1))
        assertEquals(listOf("com.whatsapp", "org.telegram"), b.apps)
    }

    @Test
    fun `an app put on a new ladera opens it, and taking it off closes it again`() {
        val b = WidgetBoard().addApp("com.whatsapp", page = 1)
        assertEquals(2, b.pages)
        assertEquals(1, b.removeApp("com.whatsapp").pages)
    }

    @Test
    fun `apps are never shelved on the camp, which has its own route`() {
        assertEquals(listOf(Shelved("com.whatsapp", 1)), WidgetBoard().addApp("com.whatsapp", page = 0).onPage(1))
    }

    @Test
    fun `uninstalled apps leave their ladera`() {
        val b = WidgetBoard().addApp("a", 1).addApp("b", 2)
        assertEquals(listOf(Shelved("a", 1)), b.keepApps(setOf("a")).items)
    }

    @Test
    fun `a widget keeps the rows you chose, from one to five`() {
        val b = board(Placed(1))
        assertEquals(3, b.resize(1, rows = 3).placed(1)?.rows)
        assertEquals(WidgetSize.MAX_ROWS, b.resize(1, rows = 9).placed(1)?.rows)
        assertEquals(1, b.resize(1, rows = 0).placed(1)?.rows)
    }

    @Test
    fun `it survives a round trip through storage, and reads the old id-only format`() {
        val b = board(Placed(4), Placed(9, page = 1, rows = 3)).addApp("com.whatsapp", page = 1)
        assertEquals(b, WidgetBoard.decode(b.encode()))
        assertEquals(board(Placed(4), Placed(9)), WidgetBoard.decode("4,9"))
        assertEquals(board(Placed(4)), WidgetBoard.decode("4,x,,"))
        assertEquals(WidgetBoard(), WidgetBoard.decode(null))
    }

    @Test
    fun `height follows the rows you chose, else the widget's target rows, else its minimum, within bounds`() {
        assertEquals(270, WidgetSize.heightDp(minHeightDp = 40, targetRows = 2, chosenRows = 3))
        assertEquals(180, WidgetSize.heightDp(minHeightDp = 40, targetRows = 2))
        assertEquals(110, WidgetSize.heightDp(minHeightDp = 110, targetRows = 0))
        assertEquals(WidgetSize.MIN_DP, WidgetSize.heightDp(minHeightDp = 10, targetRows = 0))
        assertEquals(WidgetSize.MAX_DP, WidgetSize.heightDp(minHeightDp = 900, targetRows = 0))
    }

    @Test
    fun `a widget's rows, when you have not chosen, come from its height`() {
        assertEquals(2, WidgetSize.rowsOf(heightDp = 180))
        assertEquals(1, WidgetSize.rowsOf(heightDp = 72))
        assertEquals(WidgetSize.MAX_ROWS, WidgetSize.rowsOf(heightDp = 420))
    }

    @Test
    fun `cells read like the system picker`() {
        assertEquals("4 × 2", WidgetSize.cells(targetColumns = 4, targetRows = 2))
        assertEquals("", WidgetSize.cells(targetColumns = 0, targetRows = 0))
    }

    @Test
    fun `an app can be put at a given place among the things on a ladera`() {
        val b = board(Placed(1, page = 1)).addApp("a", 1).addApp("b", 1)
        assertEquals(listOf(Shelved("b", 1), Placed(1, page = 1), Shelved("a", 1)), b.insertApp("b", page = 1, index = 0).onPage(1))
        assertEquals(listOf(Placed(1, page = 1), Shelved("b", 1), Shelved("a", 1)), b.insertApp("b", page = 1, index = 1).onPage(1))
        assertEquals(listOf(Placed(1, page = 1), Shelved("a", 1), Shelved("b", 1), Shelved("c", 1)), b.insertApp("c", page = 1, index = 99).onPage(1))
    }

    @Test
    fun `a widget can be put at a given place on any page, the camp included`() {
        val b = board(Placed(1), Placed(2), Placed(3, page = 1)).addApp("a", 1)
        assertEquals(listOf(Placed(2), Placed(1)), b.insertWidget(2, page = 0, index = 0).onPage(0))
        assertEquals(listOf(Placed(3, page = 1), Placed(1, page = 1), Shelved("a", 1)), b.insertWidget(1, page = 1, index = 1).onPage(1))
        assertEquals(listOf(Placed(1), Placed(2), Placed(3)), b.insertWidget(3, page = 0, index = 99).onPage(0))
        assertEquals(b, b.insertWidget(42, page = 0, index = 0))
    }

    @Test
    fun `a widget keeps its chosen rows when it moves`() {
        assertEquals(Placed(1, page = 1, rows = 3), board(Placed(1, rows = 3), Placed(2, page = 1)).insertWidget(1, 1, 0).placed(1))
    }
}
