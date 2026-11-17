package dev.vivac.launcher.theme

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
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

@Composable
fun Contours(modifier: Modifier = Modifier, color: Color = Ink.contour) {
    val paths = remember { contourPaths.map { PathParser().parsePathString(it).toPath() } }
    Canvas(modifier) {
        // Same placement as the 390-wide board: a 560x520 box at right -230, top -120,
        // showing viewBox (40,-70) 450x430 with "meet" scaling (centred horizontally).
        val k = size.width / 390f
        val s = minOf(560f / 450f, 520f / 430f) * k
        val left = 60f * k + (560f * k - 450f * s) / 2f
        val top = -120f * k
        withTransform({
            translate(left = left - 40f * s, top = top + 70f * s)
            scale(s, s, pivot = Offset.Zero)
        }) {
            paths.forEach { drawPath(it, color, style = Stroke(width = density / s) /* 1dp after scaling */) }
        }
    }
}

/** Motif 4, la cuerda: tense coral when tied, dashed grey when not. */
fun ropeStroke(tied: Boolean, density: Float) = Stroke(
    width = (if (tied) 3f else 2f) * density,
    pathEffect = if (tied) null else PathEffect.dashPathEffect(floatArrayOf(5f * density, 5f * density)),
)
