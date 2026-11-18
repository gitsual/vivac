package dev.vivac.launcher.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Line icons from the design: SVG path data on a 24-unit grid, 1.75 stroke, round caps. */
object Glyph {
    const val SLIDERS = "M4 7h10M18 7h2M4 17h4M12 17h8M16 5v4M10 15v4"
    const val GRID = "M5 5h4v4H5z M15 5h4v4h-4z M5 15h4v4H5z M15 15h4v4h-4z"
    const val PROMPT = "M4 17l6-6-6-6M12 19h8"
    const val SEARCH = "M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14z M20 20l-4-4"
    const val ARROW = "M5 12h14M13 6l6 6-6 6"
    const val INFO = "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z M12 11v6 M12 7.5v.5"
    const val SQUARE = "M5 5h14v14H5z"
    const val PLUS = "M12 5v14M5 12h14"
    const val MINUS = "M5 12h14"
    const val CHECK = "M5 12l5 5l9-10"
    const val LOCK = "M6 11h12v9H6z M9 11V8a3 3 0 0 1 6 0v3"
    const val EYE_OFF = "M3 3l18 18 M10.6 6.1A9.6 9.6 0 0 1 12 6c5 0 9 6 9 6a15 15 0 0 1-3 3.4 M6.6 7.6C4.3 9.2 3 12 3 12s4 6 9 6a8.6 8.6 0 0 0 4-1"
    const val EYE = "M3 12s4-6 9-6 9 6 9 6-4 6-9 6-9-6-9-6z M12 9.5a2.5 2.5 0 1 0 0 5a2.5 2.5 0 1 0 0-5z"
    const val DOT = "M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8z"
    const val DOCK = "M3 17h18 M6 13h3v4H6z M10.5 13h3v4h-3z M15 13h3v4h-3z"
    const val TENT = "M3 20L12 4l9 16z M12 20v-6"
    const val LADERA = "M3 20l6-10 3 5 3-4 6 9z M9 10V6"
    const val PETATE = "M6 8h12l-1 12H7z M9 8V6a3 3 0 0 1 6 0v2 M9 13h6"
}

@Composable
fun LineIcon(path: String, color: Color, size: Dp = 24.dp, modifier: Modifier = Modifier) {
    val parsed = remember(path) { PathParser().parsePathString(path).toPath() }
    Canvas(modifier.size(size)) {
        val k = this.size.width / 24f
        scale(k, k, pivot = androidx.compose.ui.geometry.Offset.Zero) {
            drawPath(parsed, color, style = Stroke(width = 1.75f, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
    }
}

/** Your settings for every tile: names under them, and notification counts instead of dots. */
val LocalLabels = androidx.compose.runtime.compositionLocalOf { true }
val LocalShowCounts = androidx.compose.runtime.compositionLocalOf { false }

/**
 * The tile used everywhere: a monogram or icon over a toned square, label below. On the Campamento's route
 * it carries its pitch ([badge], "L1"); [border] outlines it on the night ground.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun AppTile(
    label: String,
    background: Color,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    dot: Boolean = false,
    border: Color? = null,
    badge: String? = null,
    labelColor: Color = Ink.text,
    tile: Dp = 56.dp,
    /** Replaces the tile's own tap and long press, for tiles that can also be dragged (see the Campamento). */
    gestures: Modifier? = null,
    /** Notifications waiting; drawn as a number instead of the dot when you chose counts. */
    count: Int = 0,
    content: @Composable () -> Unit,
) {
    val number = if (LocalShowCounts.current && count > 0) count else 0
    val showLabel = LocalLabels.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .then(
                gestures ?: Modifier.combinedClickable(role = Role.Button, onClickLabel = "Abrir $label", onLongClickLabel = onLongClick?.let { "Opciones de $label" }, onLongClick = onLongClick, onClick = onClick),
            )
            .semantics {
                if (number > 0) stateDescription = "$number avisos" else if (dot) stateDescription = "con avisos"
                // With names hidden, TalkBack still reads them.
                if (!showLabel) contentDescription = label
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // A badge hangs over the tile's top edge; the tile moves down to make room so nothing is clipped.
        Box(Modifier.size(width = tile, height = if (badge != null) tile + BADGE_OVERHANG else tile)) {
            val shape = RoundedCornerShape(tile / 3)
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .size(tile)
                    .clip(shape)
                    .background(background)
                    .then(if (border != null) Modifier.border(1.dp, border, shape) else Modifier),
                contentAlignment = Alignment.Center,
            ) { content() }
            if (badge != null) {
                Text(
                    badge,
                    style = Type.mono.copy(fontSize = 9.sp, lineHeight = 12.sp, color = Ink.deep),
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .offset(x = 4.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .background(Ink.accentText)
                        .padding(horizontal = 4.dp, vertical = 1.dp),
                )
            }
            // Notification count: the number on a coral pill, ringed like the dot.
            if (number > 0) {
                Text(
                    if (number > 99) "99+" else number.toString(),
                    style = Type.mono.copy(fontSize = 10.sp, lineHeight = 12.sp, color = Ink.deep, textAlign = TextAlign.Center),
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = 5.dp, y = (-4).dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Ink.deep)
                        .padding(2.dp)
                        .clip(RoundedCornerShape(7.dp))
                        .background(Ink.primary)
                        .padding(horizontal = 4.dp, vertical = 1.dp),
                )
            } else if (dot) {
            // Notification dot: coral with a ring of the page colour so it reads on any icon.
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = 3.dp, y = (-3).dp)
                        .size(14.dp)
                        .clip(CircleShape)
                        .background(Ink.deep)
                        .padding(2.5.dp)
                        .clip(CircleShape)
                        .background(Ink.primary),
                )
            }
        }
        if (showLabel) {
            Text(
                label,
                style = Type.label.copy(color = labelColor),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** How far a pitch badge rises above its tile. */
val BADGE_OVERHANG = 6.dp

@Composable
fun Monogram(text: String, color: Color) {
    Text(text, style = Type.monogram, color = color)
}
