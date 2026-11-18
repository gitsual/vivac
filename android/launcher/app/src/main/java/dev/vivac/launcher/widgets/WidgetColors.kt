package dev.vivac.launcher.widgets

import android.util.SparseIntArray

/**
 * vivac's palette as Android's dynamic colours, for widgets. A widget drawn with the system's colours (Material You,
 * Android 12 onwards) takes these instead of the wallpaper's: neutrals from paper to night, coral as its main
 * accent, glacier and summit green as the other two. Widgets with colours of their own keep them.
 */
object WidgetColors {
    /** The tones each ramp has, lightest to darkest, as Android numbers them. */
    private val STEPS = listOf(0, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000)

    val neutral = longArrayOf(0xFFF4E9D0, 0xFFF4E9D0, 0xFFF0E2C2, 0xFFE8D5AB, 0xFFD4C2A0, 0xFFC0AD95, 0xFF9A7F8C, 0xFF7A6570, 0xFF5A4752, 0xFF43363F, 0xFF362836, 0xFF2D1F2D, 0xFF18131B)
    val coral = longArrayOf(0xFFFFF4F4, 0xFFFFECEC, 0xFFFBD9DA, 0xFFF7C4C6, 0xFFF0A3A6, 0xFFE88D91, 0xFFE1777D, 0xFFC9606A, 0xFFA84B55, 0xFF853A43, 0xFF5E2A31, 0xFF3E1C21, 0xFF1E0E11)
    val glacier = longArrayOf(0xFFF2FAFC, 0xFFE6F4F7, 0xFFCFE7ED, 0xFFB5D9E1, 0xFF8FBFCA, 0xFF7DB2BE, 0xFF6CA4B1, 0xFF578B97, 0xFF45707A, 0xFF34555D, 0xFF243B41, 0xFF172629, 0xFF0B1315)
    val summit = longArrayOf(0xFFF1FAF5, 0xFFE4F5EB, 0xFFCFEBDD, 0xFFB4DFC8, 0xFF8FCDAE, 0xFF7DBFA3, 0xFF55A185, 0xFF44866E, 0xFF356B58, 0xFF275043, 0xFF1A372D, 0xFF10231D, 0xFF08120E)

    /** Android's colour resource for one tone of one ramp, e.g. ("accent1", 400) → system_accent1_400. */
    private fun id(ramp: String, step: Int): Int =
        android.R.color::class.java.getField("system_${ramp}_$step").getInt(null)

    /**
     * A tint for widgets with colours of their own: black becomes vivac's card (#2D1F2D), white its paper
     * (#E8D5AB), everything between them in proportion. Alpha is left alone.
     */
    fun tint(): android.graphics.ColorMatrix {
        val dark = intArrayOf(0x2D, 0x1F, 0x2D)
        val light = intArrayOf(0xE8, 0xD5, 0xAB)
        fun row(c: Int) = FloatArray(5).also { r -> r[c] = (light[c] - dark[c]) / 255f; r[4] = dark[c].toFloat() }
        return android.graphics.ColorMatrix(row(0) + row(1) + row(2) + floatArrayOf(0f, 0f, 0f, 1f, 0f))
    }

    /** Every system colour a widget may use, mapped to vivac's. */
    fun resources(): SparseIntArray = SparseIntArray().apply {
        listOf("neutral1" to neutral, "neutral2" to neutral, "accent1" to coral, "accent2" to glacier, "accent3" to summit).forEach { (ramp, tones) ->
            STEPS.forEachIndexed { i, step -> put(id(ramp, step), tones[i].toInt()) }
        }
    }
}
