package dev.vivac.launcher.theme

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toArgb

/**
 * The lock screen's wallpaper: the camp's night standing still. The rings around the lamp at mid-step and the beam
 * at rest, so unlocking lands on the same night, now moving. Android owns the lock screen itself (clock,
 * notifications); vivac can only give it this picture.
 */
object LockNight {
    /** The lamp's circle, as on the camp. */
    const val INNER_DP = 30f

    /** Where the lamp hangs: the camp's settings corner, top right, below the status bar. */
    fun lamp(width: Int, density: Float) = Offset(width - 48f * density, 96f * density)

    fun paint(width: Int, height: Int, density: Float): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Ink.deep.toArgb())
        val lamp = lamp(width, density)
        val inner = INNER_DP * density

        val (a, b) = beamEdges(lamp, width.toFloat(), height.toFloat())
        val far = Offset((a.x + b.x) / 2, (a.y + b.y) / 2)
        val primary = Ink.primary.toArgb()
        val beam = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                lamp.x, lamp.y, far.x, far.y,
                intArrayOf(withAlpha(primary, Motion.GLOW_MIN), withAlpha(primary, 0.05f), 0),
                floatArrayOf(0f, 0.35f, 0.6f),
                Shader.TileMode.CLAMP,
            )
        }
        canvas.drawPath(Path().apply { moveTo(lamp.x, lamp.y); lineTo(a.x, a.y); lineTo(b.x, b.y); close() }, beam)

        val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = density
            color = Ink.surface.toArgb()
        }
        canvas.drawCircle(lamp.x, lamp.y, inner, ring)
        Rings.travelling(0.5f).forEach { (u, alpha) ->
            val outline = Rings.points(u, lamp, inner)
            val path = Path().apply {
                moveTo(outline[0].x, outline[0].y)
                outline.drop(1).forEach { lineTo(it.x, it.y) }
                close()
            }
            canvas.drawPath(path, Paint(ring).apply { this.alpha = (255 * alpha).toInt() })
        }
        return bitmap
    }

    private fun withAlpha(argb: Int, alpha: Float) = (argb and 0x00FFFFFF) or ((255 * alpha).toInt() shl 24)
}
