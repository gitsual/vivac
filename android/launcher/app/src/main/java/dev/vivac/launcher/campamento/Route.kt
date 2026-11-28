package dev.vivac.launcher.campamento

/**
 * The "Vía del campamento": pinned apps drawn as the pitches of a climbing route.
 * Like a topo, the line snakes: one row left to right, the next right to left.
 */
object Route {
    /** Grid rows of pitch indices; a null cell is empty. A right-to-left row keeps its pitches on the right. */
    fun rows(count: Int, columns: Int): List<List<Int?>> =
        (0 until count).chunked(columns).mapIndexed { row, pitches ->
            val padded = pitches + List(columns - pitches.size) { null }
            if (row % 2 == 0) padded else padded.reversed()
        }
}
