package dev.vivac.launcher.theme

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.platform.LocalContext
import kotlin.math.PI
import kotlin.math.sin
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.PathParser

/** Motif 1, curvas de nivel: the contour rings drawn behind the Campamento, from the design's SVG. */
private val contourPaths = listOf(
    "M262 100C285 100 300 120 296 140C292 160 270 168 252 162C232 155 226 135 233 118C238 106 248 100 262 100Z",
    "M260 60C310 62 350 110 340 150C330 195 285 215 245 205C200 195 180 160 190 120C198 85 225 58 260 60Z",
    "M262 30C335 30 385 100 372 160C358 225 295 250 238 240C170 228 145 175 158 118C170 65 210 30 262 30Z",
    "M265 0C360 -2 420 90 405 170C390 255 300 290 225 278C140 265 110 190 126 115C142 45 190 2 265 0Z",
    "M270 -30C390 -35 455 80 438 180C420 285 305 330 210 315C105 298 70 205 92 110C112 25 175 -27 270 -30Z",
)

/** The contour rings breathe: a slow swell that leaves the summit and travels outwards, like a wave. */
object Motion {
    /** How much a ring grows at the crest of the swell: 3 %, enough to feel, never to distract. */
    const val AMPLITUDE = 0.03f
    /** One swell every nine seconds. */
    const val PERIOD_MS = 9_000
    /** How far behind the innermost ring the outermost one rides, as a share of the period. */
    private const val LAG = 0.35f

    /** No motion when Android's animations are off (Developer options or the accessibility "remove animations"). */
    fun allowed(context: Context): Boolean =
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f

    /** The scale of [ring] (0 = innermost) at [phase] (0..1 of the period). */
    fun swell(phase: Float, ring: Int, rings: Int): Float =
        1f + AMPLITUDE * sin(2f * PI.toFloat() * (phase - LAG * ring / rings))
}

/** The summit the rings circle, in the paths' own units. */
private val SUMMIT = Offset(262f, 130f)

@Composable
fun Contours(modifier: Modifier = Modifier, color: Color = Ink.contour) {
    val paths = remember { contourPaths.map { PathParser().parsePathString(it).toPath() } }
    val moving = Motion.allowed(LocalContext.current)
    // Read only while drawing: the swell redraws the canvas, it never recomposes the screen.
    val phase = if (moving) {
        rememberInfiniteTransition(label = "contours").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(Motion.PERIOD_MS, easing = LinearEasing)),
            label = "swell",
        )
    } else null
    Canvas(modifier) {
        // Same placement as the 390-wide board: a 560x520 box at right -230, top -120,
        // showing viewBox (40,-70) 450x430 with "meet" scaling (centred horizontally).
        val k = size.width / 390f
        val s = minOf(560f / 450f, 520f / 430f) * k
        val left = 60f * k + (560f * k - 450f * s) / 2f
        val top = -120f * k
        val t = phase?.value ?: 0.25f
        withTransform({
            translate(left = left - 40f * s, top = top + 70f * s)
            scale(s, s, pivot = Offset.Zero)
        }) {
            paths.forEachIndexed { i, path ->
                val g = if (phase == null) 1f else Motion.swell(t, i, paths.size)
                scale(g, g, pivot = SUMMIT) {
                    drawPath(path, color, style = Stroke(width = density / s) /* 1dp after scaling */)
                }
            }
        }
    }
}
