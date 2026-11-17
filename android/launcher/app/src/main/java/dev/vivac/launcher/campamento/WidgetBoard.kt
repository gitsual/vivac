package dev.vivac.launcher.campamento

/** The widgets on the Campamento, as the app-widget ids Android gave them, top to bottom. */
data class WidgetBoard(val ids: List<Int> = emptyList()) {
    fun add(id: Int) = if (id in ids) this else WidgetBoard(ids + id)

    fun remove(id: Int) = WidgetBoard(ids - id)

    fun encode(): String = ids.joinToString(",")

    companion object {
        fun decode(raw: String?) = WidgetBoard(raw.orEmpty().split(",").mapNotNull { it.trim().toIntOrNull() }.distinct())
    }
}

/** How tall a widget is drawn on the Campamento, and how its size reads in the picker. */
object WidgetSize {
    const val MIN_DP = 72
    const val MAX_DP = 420

    /** Roughly the row height of a stock launcher grid on a Pixel. */
    private const val ROW_DP = 90

    fun heightDp(minHeightDp: Int, targetRows: Int): Int {
        val wanted = if (targetRows > 0) targetRows * ROW_DP else minHeightDp
        return wanted.coerceIn(MIN_DP, MAX_DP)
    }

    fun cells(targetColumns: Int, targetRows: Int): String =
        if (targetColumns > 0 && targetRows > 0) "$targetColumns × $targetRows" else ""
}
