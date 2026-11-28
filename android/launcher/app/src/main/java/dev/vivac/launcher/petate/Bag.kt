package dev.vivac.launcher.petate

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.theme.Brand
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.Type

/*
 * The petate drawn as what it is: a stuff sack. A drawcord closes its mouth (the search), the cloth is ripstop with
 * stitched seams, the apps ride inside behind a zip, and
 * the altimeter is a webbing strap with its buckle. Only vivac's own palette; the seams are papel at low alpha.
 */

private val Seam = Brand.papel300.copy(alpha = 0.45f)
private val Stitch = PathEffect.dashPathEffect(floatArrayOf(10f, 7f))

/** The drawcord over the bag's mouth, its two tails and the cord lock. Decoration only. */
@Composable
fun BagCord(modifier: Modifier = Modifier) {
    Canvas(modifier.fillMaxWidth().height(30.dp)) {
        val w = size.width
        val stroke = Stroke(width = 2.4.dp.toPx(), cap = StrokeCap.Round)
        val lockX = w - 40.dp.toPx()
        val cord = Path().apply {
            moveTo(6.dp.toPx(), 22.dp.toPx())
            cubicTo(w * 0.2f, 14.dp.toPx(), w * 0.36f, 26.dp.toPx(), w * 0.52f, 18.dp.toPx())
            cubicTo(w * 0.68f, 11.dp.toPx(), w * 0.8f, 14.dp.toPx(), lockX, 20.dp.toPx())
        }
        drawPath(cord, Ink.accentText, style = stroke)
        val tails = Path().apply {
            moveTo(lockX, 20.dp.toPx()); cubicTo(lockX + 10.dp.toPx(), 22.dp.toPx(), lockX + 14.dp.toPx(), 10.dp.toPx(), lockX + 18.dp.toPx(), 4.dp.toPx())
            moveTo(lockX, 20.dp.toPx()); cubicTo(lockX + 12.dp.toPx(), 24.dp.toPx(), lockX + 22.dp.toPx(), 18.dp.toPx(), lockX + 26.dp.toPx(), 10.dp.toPx())
        }
        drawPath(tails, Ink.accentText, style = stroke)
        val lock = Size(16.dp.toPx(), 22.dp.toPx())
        val at = Offset(lockX - lock.width / 2, 12.dp.toPx())
        drawRoundRect(Ink.field, at, lock, CornerRadius(6.dp.toPx()))
        drawRoundRect(Ink.textMuted, at, lock, CornerRadius(6.dp.toPx()), style = Stroke(1.4.dp.toPx()))
        drawCircle(Ink.deep, 2.4.dp.toPx(), Offset(lockX, 19.dp.toPx()))
    }
}

private val BagShape = RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp, bottomStart = 34.dp, bottomEnd = 34.dp)

/** The bag's cloth: ripstop grid, a hairline edge and a reinforced, darker base. */
fun Modifier.bagCloth(): Modifier = this
    .clip(BagShape)
    .background(Ink.surface)
    .drawBehind {
        val step = 7.dp.toPx()
        val thread = Brand.papel100.copy(alpha = 0.035f)
        var x = 0f
        while (x < size.width) { drawLine(thread, Offset(x, 0f), Offset(x, size.height), 1f); x += step }
        var y = 0f
        while (y < size.height) { drawLine(thread, Offset(0f, y), Offset(size.width, y), 1f); y += step }
        drawRect(Ink.deep.copy(alpha = 0.35f), Offset(0f, size.height - 10.dp.toPx()), Size(size.width, 10.dp.toPx()))
    }
    .border(1.dp, Ink.field, BagShape)

/** The gathered hem under the cord: folds of cloth and the seam that holds them. */
@Composable
fun BagHem() {
    Canvas(Modifier.fillMaxWidth().height(14.dp)) {
        drawRect(Ink.deep.copy(alpha = 0.35f))
        val fold = Brand.papel100.copy(alpha = 0.10f)
        var x = 0f
        while (x < size.width) { drawLine(fold, Offset(x, 0f), Offset(x, size.height), 1f); x += 9.dp.toPx() }
        drawLine(Seam, Offset(0f, size.height - 0.5f), Offset(size.width, size.height - 0.5f), 1.dp.toPx(), pathEffect = Stitch)
    }
}

/** "Petate", sewn on as a woven label. */
@Composable
fun BagTag() {
    Box(
        Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(Ink.raised)
            .drawBehind {
                val inset = 3.dp.toPx()
                drawRoundRect(Seam, Offset(inset, inset), Size(size.width - 2 * inset, size.height - 2 * inset), CornerRadius(6.dp.toPx()), style = Stroke(1.5.dp.toPx(), pathEffect = Stitch))
            }
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text("Petate", style = Type.title.copy(fontSize = 22.sp, lineHeight = 26.sp, letterSpacing = (-0.03).em, color = Brand.papel50), modifier = Modifier.semantics { heading() })
    }
}

/** The woven label and the strap loop beside it. */
@Composable
fun BagLabel() {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        BagTag()
        Box(Modifier.weight(1f))
        Box(Modifier.size(width = 34.dp, height = 12.dp).clip(RoundedCornerShape(6.dp)).background(Ink.field).border(1.dp, Ink.borderControl, RoundedCornerShape(6.dp)))
    }
}

/** A zip pull: a tab with its ring hole. Selected is coral filled and bold, never colour alone. */
@Composable
fun PullTab(text: String, on: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(topStart = 10.dp, bottomStart = 10.dp, topEnd = 18.dp, bottomEnd = 18.dp)
    Box(
        Modifier
            .heightIn(min = 44.dp)
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics { selected = on },
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier
                .height(36.dp)
                .clip(shape)
                .background(if (on) Ink.primary else Ink.raised)
                .border(1.dp, if (on) Ink.primary else Ink.field, shape)
                .padding(start = 10.dp, end = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            Box(Modifier.size(8.dp).border(1.5.dp, if (on) Ink.onPrimary else Ink.borderControl, CircleShape))
            Text(text, style = Type.body.copy(fontSize = 14.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Medium), color = if (on) Ink.onPrimary else Ink.text)
        }
    }
}

/** The zip across the main compartment: a tape with its teeth. */
@Composable
fun Zipper() {
    Canvas(Modifier.fillMaxWidth().height(8.dp)) {
        drawLine(Ink.field, Offset(0f, 0.5f), Offset(size.width, 0.5f), 1f)
        drawLine(Ink.field, Offset(0f, size.height - 0.5f), Offset(size.width, size.height - 0.5f), 1f)
        val tooth = 3.dp.toPx()
        var x = 0f
        while (x < size.width) { drawRect(Ink.borderControl, Offset(x, 2.5.dp.toPx()), Size(tooth, 3.dp.toPx())); x += 2 * tooth }
    }
}

/** The webbing strap the altimeter runs along: stitched edges and a buckle on top. */
fun Modifier.strap(): Modifier = this
    .background(Ink.raised)
    .drawBehind {
        drawLine(Seam, Offset(0.5f, 0f), Offset(0.5f, size.height), 1f, pathEffect = Stitch)
        drawLine(Seam, Offset(size.width - 0.5f, 0f), Offset(size.width - 0.5f, size.height), 1f, pathEffect = Stitch)
    }

@Composable
fun Buckle() {
    Box(Modifier.padding(vertical = 4.dp).size(width = 20.dp, height = 12.dp).border(1.5.dp, Ink.textMuted, RoundedCornerShape(3.dp)))
}
