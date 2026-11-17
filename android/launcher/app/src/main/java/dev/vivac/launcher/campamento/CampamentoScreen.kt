package dev.vivac.launcher.campamento

import android.content.Context
import android.view.View
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import dev.vivac.launcher.theme.Motion
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.AppFace
import dev.vivac.launcher.apps.LocalDots
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.petate.Pack
import dev.vivac.launcher.theme.AppTile
import dev.vivac.launcher.theme.BADGE_OVERHANG
import dev.vivac.launcher.theme.Contours
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

@Composable
fun CampamentoScreen(
    stamp: String,
    facts: PhoneFacts,
    apps: List<InstalledApp>,
    home: Home,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    onOpenPetate: (search: Boolean) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenAbout: () -> Unit,
    onShowNotifications: () -> Unit,
    widgetIds: List<Int>,
    widgetHeightDp: (Int) -> Int,
    widgetView: (Context, Int, Float) -> View?,
    onCampMenu: () -> Unit,
) {
    val onSwipe: (Swipe) -> Unit = { s ->
        when (s) {
            Swipe.DOWN -> onShowNotifications()
            Swipe.UP -> onOpenPetate(false)
            Swipe.NONE -> Unit
        }
    }
    val density = LocalDensity.current.density
    // Drags the middle area could not scroll (already at its top or bottom) still count as swipes.
    val leftovers = remember { SwipeLeftovers(density, onSwipe) }
    Box(
        Modifier
            .fillMaxSize()
            .background(Ink.deep)
            .swipes(onSwipe)
            .pointerInput(Unit) { detectTapGestures(onLongPress = { onCampMenu() }) },
    ) {
        Contours(Modifier.fillMaxSize(), color = Ink.surface)
        Beam(Modifier.fillMaxSize())
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Header(onOpenSettings)
            Clock(stamp)
            Column(
                Modifier
                    .weight(1f)
                    .nestedScroll(leftovers)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                FactsStrip(facts, onOpenAbout)
                widgetIds.forEach { id -> WidgetCard(id, widgetHeightDp(id), widgetView) }
                Via(apps, home.pinned, onOpenApp, onAppMenu)
            }
            SearchPill { onOpenPetate(true) }
            DockCard(apps, home.dock, onOpenApp, onAppMenu) { onOpenPetate(false) }
        }
    }
}

/** A placed widget, drawn by its app inside a vivac card shape. */
@Composable
private fun WidgetCard(id: Int, heightDp: Int, widgetView: (Context, Int, Float) -> View?) {
    BoxWithConstraints(
        Modifier
            .fillMaxWidth()
            .height(heightDp.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.field, RoundedCornerShape(24.dp)),
    ) {
        val width = maxWidth.value
        // key(id): a new widget id must get a fresh host view, never a recycled one.
        key(id) {
            AndroidView(
                factory = { ctx -> widgetView(ctx, id, width) ?: android.widget.Space(ctx) },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/** Feeds the scroll area's unconsumed drag into the same swipe rules as the rest of the screen. */
private class SwipeLeftovers(private val density: Float, private val onSwipe: (Swipe) -> Unit) : NestedScrollConnection {
    private var pull = 0f

    override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
        if (source == NestedScrollSource.UserInput) pull += available.y
        return Offset.Zero
    }

    override suspend fun onPreFling(available: Velocity): Velocity {
        val swipe = Swipe.classify(dyDp = pull / density, velocityDp = available.y / density)
        pull = 0f
        onSwipe(swipe)
        return Velocity.Zero
    }
}

/** Vertical swipes anywhere on the Campamento; taps on cards and tiles still go through. */
private fun Modifier.swipes(onSwipe: (Swipe) -> Unit): Modifier = pointerInput(Unit) {
    val tracker = VelocityTracker()
    var dy = 0f
    detectVerticalDragGestures(
        onDragStart = {
            dy = 0f
            tracker.resetTracking()
        },
        onVerticalDrag = { change, amount ->
            dy += amount
            tracker.addPosition(change.uptimeMillis, change.position)
        },
        onDragEnd = {
            onSwipe(Swipe.classify(dyDp = dy / density, velocityDp = tracker.calculateVelocity().y / density))
        },
    )
}

/** Motif 2, la frontal: the headlamp's beam falling across the camp from the settings corner, swaying gently. */
@Composable
private fun Beam(modifier: Modifier) {
    val moving = Motion.allowed(LocalContext.current)
    // Read only while drawing: the sway redraws the canvas, it never recomposes the screen.
    val phase = if (moving) {
        rememberInfiniteTransition(label = "lamp").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(Motion.LAMP_PERIOD_MS, easing = LinearEasing)),
            label = "sway",
        )
    } else null
    Canvas(modifier) {
        val t = phase?.value ?: 0f
        val origin = Offset(size.width - 46.dp.toPx(), 66.dp.toPx())
        val beam = Path().apply {
            moveTo(origin.x, origin.y)
            lineTo(-60.dp.toPx(), size.height * 0.5f)
            lineTo(70.dp.toPx(), size.height * 0.66f)
            close()
        }
        rotate(Motion.sway(t), pivot = origin) {
            drawPath(
                beam,
                Brush.linearGradient(
                    0f to Ink.primary.copy(alpha = Motion.glow(t)),
                    0.55f to Ink.primary.copy(alpha = 0.06f),
                    1f to Color.Transparent,
                    start = origin,
                    end = Offset(0f, size.height * 0.62f),
                ),
            )
        }
    }
}

@Composable
private fun Header(onOpenSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("CAMPAMENTO", style = Type.cota, modifier = Modifier.weight(1f).semantics { heading() })
        // The headlamp itself: the beam starts here.
        Box(
            Modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(Ink.surface)
                .border(1.5.dp, Ink.accentText, CircleShape)
                .clickable(role = Role.Button, onClickLabel = "Abrir ajustes", onClick = onOpenSettings)
                .semantics { contentDescription = "Ajustes del sistema" },
            contentAlignment = Alignment.Center,
        ) { LineIcon(Glyph.SLIDERS, Ink.accentText, 22.dp) }
    }
}

/** The hour, as big as the night allows, and the date stacked like a summit marker. */
@Composable
private fun Clock(stamp: String) {
    val time = stamp.substringAfter(" · ", stamp)
    val day = stamp.substringBefore(" · ", "").split(" ")
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Text(time, style = Type.hour, modifier = Modifier.weight(1f))
        if (day.size == 3) {
            Column(Modifier.padding(bottom = 10.dp), horizontalAlignment = Alignment.End) {
                Text(day[0], style = Type.mono)
                Text(day[1], style = Type.figure.copy(fontSize = 22.sp, lineHeight = 26.sp))
                Text(day[2], style = Type.mono)
            }
        }
    }
}

/** Battery, free space and the GrapheneOS build as map annotations between two hairlines. */
@Composable
private fun FactsStrip(facts: PhoneFacts, onOpenAbout: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .drawBehind {
                val w = 1.dp.toPx()
                drawLine(Ink.field, Offset(0f, 0f), Offset(size.width, 0f), w)
                drawLine(Ink.field, Offset(0f, size.height), Offset(size.width, size.height), w)
            },
    ) {
        Fact("BATERÍA", "${facts.batteryPercent} %", Modifier.weight(1f)) {
            if (facts.charging) Text("cargando", style = Type.mono, color = Ink.okText)
            else Gauge(facts.batteryPercent / 100f)
        }
        Rule()
        Fact("LIBRE", "${facts.freeGb} GB", Modifier.weight(1f)) {
            Gauge(if (facts.totalGb > 0) facts.freeGb.toFloat() / facts.totalGb else 0f)
        }
        Rule()
        Fact(
            "GRAPHENEOS",
            facts.build,
            Modifier
                .weight(1f)
                .clickable(role = Role.Button, onClickLabel = "Ver información del teléfono", onClick = onOpenAbout),
            valueStyle = Type.mono.copy(fontSize = 13.sp, lineHeight = 26.sp, color = Ink.text),
        ) { Text("parche ${facts.securityPatch}", style = Type.mono.copy(fontSize = 10.sp), maxLines = 1) }
    }
}

@Composable
private fun Fact(
    caption: String,
    value: String,
    modifier: Modifier,
    valueStyle: TextStyle = Type.figure.copy(fontSize = 20.sp, lineHeight = 26.sp),
    detail: @Composable () -> Unit,
) {
    Column(modifier.padding(start = 10.dp, top = 10.dp, bottom = 10.dp, end = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(caption, style = Type.cota.copy(fontSize = 10.sp))
        Text(value, style = valueStyle, maxLines = 1)
        detail()
    }
}

@Composable
private fun Rule() {
    Box(Modifier.width(1.dp).fillMaxHeight().background(Ink.field))
}

/** A measure bar: glaciar, the colour kept for measures only. */
@Composable
private fun Gauge(fraction: Float) {
    Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Ink.field)) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).fillMaxHeight().background(Ink.measure))
    }
}

private val TILE = 60.dp
private val ROW_GAP = 10.dp

/**
 * Motif 3, la vía: the apps you pinned are the pitches of a route, L1 onwards, joined by a dashed line
 * that snakes like a topo (see [Route]).
 */
@Composable
private fun Via(apps: List<InstalledApp>, pinned: List<String>, onOpenApp: (String) -> Unit, onAppMenu: (String) -> Unit) {
    val byPackage = apps.associateBy { it.packageName }
    val shown = pinned.mapNotNull { byPackage[it] }
    if (shown.isEmpty()) return
    val rows = Route.rows(shown.size, 4)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text("Vía del campamento", style = Type.section, modifier = Modifier.weight(1f).semantics { heading() })
            Text("${shown.size} ${if (shown.size == 1) "LARGO" else "LARGOS"} · A MANO", style = Type.cota.copy(fontSize = 10.sp))
        }
        val dash = with(LocalDensity.current) { floatArrayOf(2.dp.toPx(), 7.dp.toPx()) }
        Column(
            Modifier
                .fillMaxWidth()
                .drawBehind {
                    val cell = size.width / 4
                    val rowH = (size.height + ROW_GAP.toPx()) / rows.size
                    val centre = { index: Int ->
                        val r = rows.indexOfFirst { index in it }
                        Offset(cell * (rows[r].indexOf(index) + 0.5f), r * rowH + BADGE_OVERHANG.toPx() + TILE.toPx() / 2)
                    }
                    val line = Path()
                    shown.indices.forEach { i ->
                        val p = centre(i)
                        if (i == 0) line.moveTo(p.x, p.y)
                        else {
                            val q = centre(i - 1)
                            if (q.y == p.y) line.lineTo(p.x, p.y)
                            else {
                                // Turn round the edge of the wall, outwards.
                                val out = if (q.x > size.width / 2) cell * 0.55f else -cell * 0.55f
                                line.cubicTo(q.x + out, q.y, p.x + out, p.y, p.x, p.y)
                            }
                        }
                    }
                    drawPath(
                        line,
                        Ink.primary.copy(alpha = 0.75f),
                        style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(dash)),
                    )
                },
            verticalArrangement = Arrangement.spacedBy(ROW_GAP),
        ) {
            rows.forEach { row ->
                Row(Modifier.fillMaxWidth()) {
                    row.forEach { index ->
                        if (index == null) Spacer(Modifier.weight(1f))
                        else {
                            val app = shown[index]
                            AppTile(
                                label = app.label,
                                background = Ink.surface,
                                border = Ink.field,
                                badge = Route.pitch(index),
                                tile = TILE,
                                onClick = { onOpenApp(app.packageName) },
                                onLongClick = { onAppMenu(app.packageName) },
                                dot = app.packageName in LocalDots.current,
                                modifier = Modifier.weight(1f),
                            ) { AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchPill(onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(48.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.borderControl, RoundedCornerShape(999.dp))
            .clickable(role = Role.Button, onClickLabel = "Buscar en el petate", onClick = onClick)
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LineIcon(Glyph.SEARCH, Ink.text, 18.dp)
        Text("buscar en el petate…", style = Type.body.copy(fontSize = 15.sp, color = Ink.textMuted), modifier = Modifier.weight(1f))
        Text("DESLIZA ↑", style = Type.cota.copy(fontSize = 10.sp))
    }
}

/** Motif 4, la cordada: the apps you always carry, roped to the Petate, which closes the line in coral. */
@Composable
private fun DockCard(apps: List<InstalledApp>, chosen: List<String>, onOpenApp: (String) -> Unit, onAppMenu: (String) -> Unit, onOpenPetate: () -> Unit) {
    val byPackage = apps.associateBy { it.packageName }
    val slots = Dock.pick(byPackage.keys, chosen)
    Column(
        Modifier
            .fillMaxWidth()
            .padding(bottom = 12.dp)
            .clip(RoundedCornerShape(28.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.field, RoundedCornerShape(28.dp))
            .padding(start = 8.dp, end = 8.dp, top = 10.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("LA CORDADA", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.padding(start = 10.dp))
        // Five equal columns: on a 412dp Pixel five fixed tiles do not fit and labels got clipped.
        Row(Modifier.fillMaxWidth()) {
            slots.forEach { slot ->
                when (slot) {
                    is DockSlot.App -> {
                        val app = byPackage.getValue(slot.packageName)
                        val deep = app.packageName == "com.termux"
                        AppTile(
                            label = app.label,
                            background = if (deep) Ink.deep else Ink.field,
                            onClick = { onOpenApp(app.packageName) },
                            onLongClick = { onAppMenu(app.packageName) },
                            dot = app.packageName in LocalDots.current,
                            modifier = Modifier.weight(1f),
                        ) { AppFace(app, if (deep) Ink.ok else Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]) }
                    }
                    DockSlot.Petate -> AppTile(
                        label = "Petate",
                        background = Ink.primary,
                        labelColor = Ink.accentText,
                        onClick = onOpenPetate,
                        modifier = Modifier.weight(1f),
                    ) { LineIcon(Glyph.PETATE, Ink.onPrimary) }
                }
            }
        }
    }
}
