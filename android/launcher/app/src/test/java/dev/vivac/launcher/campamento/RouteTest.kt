package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Test

class RouteTest {
    @Test
    fun `the route snakes, left to right, then right to left, like a climbing topo`() {
        assertEquals(
            listOf(listOf(0, 1, 2, 3), listOf(7, 6, 5, 4)),
            Route.rows(count = 8, columns = 4),
        )
    }

    @Test
    fun `a short return row keeps its pitches on the right, under where the route turned`() {
        assertEquals(listOf(listOf(0, 1, 2, 3), listOf(null, null, 5, 4)), Route.rows(count = 6, columns = 4))
    }

    @Test
    fun `a third row turns again, to the left`() {
        assertEquals(
            listOf(listOf(0, 1, 2, 3), listOf(7, 6, 5, 4), listOf(8, 9, null, null)),
            Route.rows(count = 10, columns = 4),
        )
    }

    @Test
    fun `few or no pins`() {
        assertEquals(listOf(listOf(0, 1, null, null)), Route.rows(count = 2, columns = 4))
        assertEquals(emptyList<List<Int?>>(), Route.rows(count = 0, columns = 4))
    }
}
