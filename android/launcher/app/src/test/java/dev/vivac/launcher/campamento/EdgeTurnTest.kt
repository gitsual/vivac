package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Test

class EdgeTurnTest {
    private fun EdgeTurn.at(x: Float) = check(x, left = 0f, right = 1000f, edge = 50f)

    @Test
    fun `a finger held at the edge turns one page, not one every moment`() {
        val turn = EdgeTurn()
        assertEquals(1, turn.at(990f))
        assertEquals(0, turn.at(990f))
        assertEquals(0, turn.at(995f))
    }

    @Test
    fun `leaving the edge and coming back turns one more, either side`() {
        val turn = EdgeTurn()
        assertEquals(1, turn.at(990f))
        assertEquals(0, turn.at(500f))
        assertEquals(1, turn.at(990f))
        assertEquals(0, turn.at(500f))
        assertEquals(-1, turn.at(10f))
        assertEquals(0, turn.at(10f))
    }
}
