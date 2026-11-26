package dev.vivac.launcher.theme

import androidx.compose.ui.platform.testTag
import android.content.Context
import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.animation.core.withInfiniteAnimationFrameMillis
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.dp

/** Motif 1, curvas de nivel: the contour rings drawn behind the Campamento, from the design's SVG. */
private val contourPaths = listOf(
    "M262 100C285 100 300 120 296 140C292 160 270 168 252 162C232 155 226 135 233 118C238 106 248 100 262 100Z",
    "M260 60C310 62 350 110 340 150C330 195 285 215 245 205C200 195 180 160 190 120C198 85 225 58 260 60Z",
    "M262 30C335 30 385 100 372 160C358 225 295 250 238 240C170 228 145 175 158 118C170 65 210 30 262 30Z",
    "M265 0C360 -2 420 90 405 170C390 255 300 290 225 278C140 265 110 190 126 115C142 45 190 2 265 0Z",
    "M270 -30C390 -35 455 80 438 180C420 285 305 330 210 315C105 298 70 205 92 110C112 25 175 -27 270 -30Z",
)

/**
 * The camp's rings around [centre]: the circle stays, and rings are born from it and travel out for ever, growing
 * and losing their roundness, fading far away. They are drawn in their own layer, so only the rings redraw.
 */
@Composable
private fun RingsAround(modifier: Modifier, color: Color, centre: Offset, innerRadius: androidx.compose.ui.unit.Dp) {
    val moving = Motion.allowed(LocalContext.current)
    val phase = if (moving) {
        rememberLoop(Rings.STEP_MS)
    } else null
    Canvas(modifier.graphicsLayer { }.testTag("rings")) {
        val inner = innerRadius.toPx()
        val stroke = Stroke(width = density)
        // Out to the far side of the screen, which on its side is a long way left of the lamp.
        val spread = Rings.spread(inner, reach = maxOf(centre.x, size.width - centre.x))
        drawCircle(color, inner, centre, style = stroke)
        Rings.travelling(phase?.value ?: 0.5f).forEach { (u, alpha) ->
            if (alpha <= 0f) return@forEach
            val outline = Rings.points(u, centre, inner, spread)
            // A polyline of short segments, not a stroked path: the GPU draws the segments straight away, where a
            // ring larger than the screen, stroked with antialiasing, was rasterized on the CPU into a mask the
            // size of the ring at every tick, more than half a core while the camp sat idle.
            drawPoints(
                outline + outline.first(),
                androidx.compose.ui.graphics.PointMode.Polygon,
                color.copy(alpha = color.alpha * alpha),
                strokeWidth = stroke.width,
                cap = androidx.compose.ui.graphics.StrokeCap.Round,
            )
        }
    }
}

/** The contour rings breathe: a slow swell that leaves the summit and travels outwards, like a wave. */
object Motion {
    /** How much a ring grows at the crest of the swell: 3 %, enough to feel, never to distract. */
    const val AMPLITUDE = 0.03f
    /** One swell every nine seconds. */
    const val PERIOD_MS = 9_000
    /**
     * The background loops tick 20 times a second. They are slow (seconds per cycle), so 120 Hz looked no
     * different but kept the render thread re-rasterizing every ring all the time, a whole core while idle.
     */
    const val FRAME_MS = 50L

    /** How far into a loop of [periodMs] the time [elapsedMs] is, from 0 up to 1, wrapping round. */
    fun phaseAt(elapsedMs: Long, periodMs: Int): Float = (elapsedMs % periodMs).toFloat() / periodMs
    /** How far behind the innermost ring the outermost one rides, as a share of the period. */
    private const val LAG = 0.35f

    /** No motion when Android's animations are off (Developer options or the accessibility "remove animations"). */
    fun allowed(context: Context): Boolean =
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f

    /** The headlamp: a slow sway, like someone breathing in the bivouac, every fourteen seconds. */
    /** A wide swing, from down the left to past the right edge, as quick at its quickest as the old 8° every 14 s. */
    const val SWAY_DEGREES = 28f
    const val LAMP_PERIOD_MS = 49_000
    /** The beam's strongest alpha breathes between these: dimmer, brighter, never off. */
    const val GLOW_MIN = 0.24f
    const val GLOW_MAX = 0.34f

    /** The beam's rotation in degrees at [phase] (0..1): centred, right, centred, left. */
    fun sway(phase: Float): Float = SWAY_DEGREES * sin(2f * PI.toFloat() * phase)

    /** The beam's strongest alpha at [phase]: twice per sway, so it brightens at each end of the swing. */
    fun glow(phase: Float): Float =
        GLOW_MIN + (GLOW_MAX - GLOW_MIN) * (0.5f - 0.5f * cos(4f * PI.toFloat() * phase))

    /**
     * At each end of its swing, the beam reaches a little forward and flares, as if the lamp were turned towards you
     * for a moment: 0 most of the time, rising to 1 and back over about a second.
     */
    fun flare(phase: Float): Float {
        // At each end of the swing, where the beam turns.
        val d = minOf(kotlin.math.abs(phase - 0.25f), kotlin.math.abs(phase - 0.75f))
        return if (d >= FLARE_HALF) 0f else 0.5f + 0.5f * cos(PI.toFloat() * d / FLARE_HALF)
    }
    private const val FLARE_HALF = 0.012f

    /** The scale of [ring] (0 = innermost) at [phase] (0..1 of the period). */
    fun swell(phase: Float, ring: Int, rings: Int): Float =
        1f + AMPLITUDE * sin(2f * PI.toFloat() * (phase - LAG * ring / rings))
}

/** The summit the rings circle, in the paths' own units. */
private val SUMMIT = Rings.SUMMIT

/**
 * The camp's contour rings, drawn around a summit: the first a perfect circle, each one out bigger and more
 * uneven, as contour lines get further from a peak, the last ones running far off the screen.
 */
object Rings {
    val SUMMIT = Offset(262f, 130f)
    /** How many rings travel out at once. */
    const val COUNT = 8
    /** How uneven a ring is per step out, as a share of its size: none at the circle. */
    private const val UNEVEN = 0.045f
    private const val STEPS = 144
    /** One ring's journey from the circle to the next ring's place, in milliseconds. */
    const val STEP_MS = 6_400

    /** A ring's size at [u] steps out, as many times the circle: growing faster the further out it is. */
    fun size(u: Float): Float = 1f + u + 0.25f * u * u

    /**
     * The outline of the ring [u] steps out from [centre] (0 is the circle itself, [inner] pixels in radius): bigger
     * and more uneven as [u] grows, its shape changing continuously, so a ring can travel smoothly outwards.
     */
    fun points(u: Float, centre: Offset, inner: Float, spread: Float = 1f): List<Offset> {
        val radius = inner * (1f + (size(u) - 1f) * spread)
        val uneven = UNEVEN * u
        return (0 until STEPS).map { i ->
            val a = 2.0 * PI * i / STEPS
            val wave = 0.55 * kotlin.math.sin(2 * a + 0.7 * u) + 0.3 * kotlin.math.sin(3 * a + 1.9 * u) + 0.15 * kotlin.math.sin(5 * a + 0.4 * u)
            val r = radius * (1 + uneven * wave).toFloat()
            Offset(centre.x + r * kotlin.math.cos(a).toFloat(), centre.y + r * kotlin.math.sin(a).toFloat())
        }
    }

    /**
     * The rings travelling out at [phase] (0..1 of one step): each one's place in steps and how visible it is. One
     * is born at the circle, faint, as the furthest fades away, so the end of a step is the start of the next.
     */
    /**
     * How much further apart the rings travel so the last full one gets past [reach] pixels (the screen's side
     * furthest from the centre), with a tenth to spare: 1 when they already do (upright), more on its side.
     */
    fun spread(inner: Float, reach: Float): Float =
        ((reach * 1.1f / inner - 1f) / (size(COUNT - 1f) - 1f)).coerceAtLeast(1f)

    fun travelling(phase: Float): List<Pair<Float, Float>> = (0 until COUNT).map { i ->
        val u = i + phase
        val alpha = when {
            u < 1f -> u
            u > COUNT - 1f -> COUNT - u
            else -> 1f
        }
        u to alpha.coerceIn(0f, 1f)
    }
}

/** Where the beam points at rest, in degrees clockwise from the right (90 is straight down), and its half width. */
const val BEAM_ANGLE = 112f
const val BEAM_HALF = 11f

/** The headlamp's beam: its two edges, as a narrow cone from [origin] down and to the left across the screen. */
fun beamEdges(origin: Offset, width: Float, height: Float): Pair<Offset, Offset> {
    val reach = kotlin.math.hypot(width, height) * 1.2f
    val centre = Math.toRadians(BEAM_ANGLE.toDouble())
    val half = Math.toRadians(BEAM_HALF.toDouble())
    fun edge(a: Double) = Offset(origin.x + reach * kotlin.math.cos(a).toFloat(), origin.y + reach * kotlin.math.sin(a).toFloat())
    return edge(centre - half) to edge(centre + half)
}

/**
 * Where the 390-wide board's rings land on a canvas [width] px wide: a 560x520 box at right -230, top -120,
 * showing viewBox (40,-70) 450x430 with "meet" scaling (centred horizontally). Scale, then the offset of the
 * paths' origin.
 */
private fun placement(width: Float): Triple<Float, Float, Float> {
    val k = width / 390f
    val s = minOf(560f / 450f, 520f / 430f) * k
    val left = 60f * k + (560f * k - 450f * s) / 2f
    val top = -120f * k
    return Triple(s, left - 40f * s, top + 70f * s)
}

/**
 * Each ring is drawn once into its own layer; the swell only scales that layer about the summit. The scaling is
 * applied by the render thread, so the rings breathe without redrawing anything or touching the UI thread.
 */
@Composable
fun Contours(
    modifier: Modifier = Modifier,
    color: Color = Ink.contour,
    /** Where to centre the rings, in this box's pixels, the first a circle [innerRadius] around it; else the design's rings. */
    centre: Offset? = null,
    innerRadius: androidx.compose.ui.unit.Dp = 30.dp,
) {
    if (centre != null) return RingsAround(modifier, color, centre, innerRadius)
    val paths = remember { contourPaths.map { PathParser().parsePathString(it).toPath() } }
    val moving = Motion.allowed(LocalContext.current)
    val phase = if (moving) {
        rememberLoop(Motion.PERIOD_MS)
    } else null
    Box(modifier) {
        paths.forEachIndexed { i, path ->
            Canvas(
                Modifier
                    .matchParentSize()
                    .graphicsLayer {
                        if (phase != null) {
                            val (s, x, y) = placement(size.width)
                            val g = Motion.swell(phase.value, i, paths.size)
                            scaleX = g
                            scaleY = g
                            transformOrigin = TransformOrigin((x + SUMMIT.x * s) / size.width, (y + SUMMIT.y * s) / size.height)
                        }
                    },
            ) {
                val (s, x, y) = placement(size.width)
                withTransform({
                    translate(left = x, top = y)
                    scale(s, s, pivot = Offset.Zero)
                }) {
                    drawPath(path, color, style = Stroke(width = density / s) /* 1dp after scaling */)
                }
            }
        }
    }
}

/**
 * Like an infinite transition it pauses under tests' infinite-animation policy.
 * A phase going 0 to 1 every [periodMs], for ever, updated about every [Motion.FRAME_MS]: between ticks nothing is
 * invalidated, so the screen can rest instead of drawing the background at the display's full rate.
 */
@Composable
fun rememberLoop(periodMs: Int): State<Float> {
    val phase = remember { mutableFloatStateOf(0f) }
    LaunchedEffect(periodMs) {
        val start = withInfiniteAnimationFrameMillis { it }
        var tick = -1L
        while (true) {
            withInfiniteAnimationFrameMillis { now ->
                // Only a new tick writes the phase; the frames between invalidate nothing and draw nothing.
                val t = (now - start) / Motion.FRAME_MS
                if (t != tick) {
                    tick = t
                    phase.floatValue = Motion.phaseAt(t * Motion.FRAME_MS, periodMs)
                }
            }
        }
    }
    return phase
}
