package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Test

class WidgetBoardTest {
    @Test
    fun `widgets are added in order and removed by id`() {
        val board = WidgetBoard().add(7).add(12).add(3)
        assertEquals(listOf(7, 12, 3), board.ids)
        assertEquals(listOf(7, 3), board.remove(12).ids)
    }

    @Test
    fun `adding the same id twice keeps one`() {
        assertEquals(listOf(5), WidgetBoard().add(5).add(5).ids)
    }

    @Test
    fun `it survives a round trip through storage, garbage ignored`() {
        val board = WidgetBoard(listOf(4, 9))
        assertEquals(board, WidgetBoard.decode(board.encode()))
        assertEquals(WidgetBoard(listOf(4)), WidgetBoard.decode("4,x,,"))
        assertEquals(WidgetBoard(), WidgetBoard.decode(null))
    }

    @Test
    fun `height follows the widget's target rows, else its minimum, within sane bounds`() {
        assertEquals(180, WidgetSize.heightDp(minHeightDp = 40, targetRows = 2))
        assertEquals(110, WidgetSize.heightDp(minHeightDp = 110, targetRows = 0))
        assertEquals(WidgetSize.MIN_DP, WidgetSize.heightDp(minHeightDp = 10, targetRows = 0))
        assertEquals(WidgetSize.MAX_DP, WidgetSize.heightDp(minHeightDp = 900, targetRows = 0))
        assertEquals(WidgetSize.MAX_DP, WidgetSize.heightDp(minHeightDp = 40, targetRows = 6))
    }

    @Test
    fun `cells read like the system picker`() {
        assertEquals("4 × 2", WidgetSize.cells(targetColumns = 4, targetRows = 2))
        assertEquals("", WidgetSize.cells(targetColumns = 0, targetRows = 0))
    }
}
