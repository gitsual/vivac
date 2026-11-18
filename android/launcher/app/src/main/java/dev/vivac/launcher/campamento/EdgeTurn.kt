package dev.vivac.launcher.campamento

/**
 * When a finger carrying something should turn the page: once each time it reaches the left or right edge. Staying
 * at the edge turns nothing more; the finger has to leave it and come back, so a page is never skipped by accident.
 */
class EdgeTurn {
    private var armed = true

    /** The way to turn now: -1 (back), +1 (on), or 0; [edge] is how wide each edge zone is. */
    fun check(x: Float, left: Float, right: Float, edge: Float): Int {
        val dir = when {
            x < left + edge -> -1
            x > right - edge -> 1
            else -> 0
        }
        if (dir == 0) { armed = true; return 0 }
        if (!armed) return 0
        armed = false
        return dir
    }
}
