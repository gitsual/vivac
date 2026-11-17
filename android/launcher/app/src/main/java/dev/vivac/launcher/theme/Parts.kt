package dev.vivac.launcher.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
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
    const val DOCK = "M3 17h18 M6 13h3v4H6z M10.5 13h3v4h-3z M15 13h3v4h-3z"
    const val TENT = "M3 20L12 4l9 16z M12 20v-6"
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

/** The 56dp tile used by the dock and the Petate: a monogram or icon over a toned square, label below. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun AppTile(
    label: String,
    background: Color,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .combinedClickable(role = Role.Button, onClickLabel = "Abrir $label", onLongClickLabel = onLongClick?.let { "Opciones de $label" }, onLongClick = onLongClick, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            Modifier.size(56.dp).clip(RoundedCornerShape(18.dp)).background(background),
            contentAlignment = Alignment.Center,
        ) { content() }
        Text(
            label,
            style = Type.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
fun Monogram(text: String, color: Color) {
    Text(text, style = Type.monogram, color = color)
}
