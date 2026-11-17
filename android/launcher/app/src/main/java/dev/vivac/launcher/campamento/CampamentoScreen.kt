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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.round
import dev.vivac.launcher.core.Zone
import kotlinx.coroutines.delay
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
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
import dev.vivac.launcher.widgets.Grip
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
    board: WidgetBoard,
    page: Int,
    onPage: (Int) -> Unit,
    widgetHeightDp: (id: Int, rows: Int) -> Int,
    widgetView: (Context, id: Int, widthDp: Float, rows: Int, grip: Grip) -> View?,
    onWidgetMenu: (Int) -> Unit,
    onCampMenu: () -> Unit,
    onDrop: (packageName: String, from: Zone, to: Zone, index: Int) -> Unit = { _, _, _, _ -> },
    drag: DragBoard = remember { DragBoard() },
    onWidgetDrop: (id: Int, to: Zone, index: Int) -> Unit = { _, _, _ -> },
    widgetLabel: (Int) -> String = { "widget" },
    onShortcut: (Pinned) -> Unit = {},
    onShortcutMenu: (Pinned) -> Unit = {},
) {
    val dp = LocalDensity.current.density
    val drop: (Held, Spot) -> Unit = { h, spot -> onDrop(h.app.packageName, h.from, spot.zone, spot.index) }
    var rootOrigin by remember { mutableStateOf(Offset.Zero) }
    val currentPage by rememberUpdatedState(page)
    val pageCount by rememberUpdatedState(board.pages)
    // Holding a carried app at the left or right edge for a moment turns the page.
    LaunchedEffect(drag.held) {
        if (drag.held == null) return@LaunchedEffect
        while (true) {
            delay(EDGE_WAIT_MS)
            val edge = 28f * dp
            val dir = when {
                drag.finger.x < drag.screen.left + edge -> -1
                drag.finger.x > drag.screen.right - edge -> 1
                else -> 0
            }
            if (dir != 0) onPage((currentPage + dir).coerceIn(0, pageCount - 1))
        }
    }
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
            .onGloballyPositioned { drag.screen = it.boundsInRoot(); rootOrigin = it.positionInRoot() }
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
            Header(if (page == 0) "CAMPAMENTO" else "LADERA $page", onOpenSettings)
            val pager = rememberPagerState(initialPage = page) { board.pages }
            // The launcher decides the page (home, a widget sent elsewhere); a swipe tells it where you went.
            LaunchedEffect(page) { if (pager.currentPage != page) pager.animateScrollToPage(page) }
            LaunchedEffect(pager) { snapshotFlow { pager.settledPage }.collect(onPage) }
            val card: @Composable (Placed) -> Unit = { w ->
                val spot = Spot(Zone.Ladera(w.page), board.onPage(w.page).indexOf(w))
                val grip = remember(w.id, w.page) { CardGrip(drag, HeldWidget(w.id, Zone.Ladera(w.page), widgetLabel(w.id)), { onWidgetMenu(w.id) }, onWidgetDrop) }
                WidgetCard(w.id, w.rows, widgetHeightDp(w.id, w.rows), widgetView, grip, drag, spot)
            }
            HorizontalPager(pager, Modifier.weight(1f), pageSpacing = 24.dp, verticalAlignment = Alignment.Top) { p ->
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (p == 0) Clock(stamp)
                    Column(
                        Modifier
                            .weight(1f)
                            // The camp takes a carried widget anywhere over it, after its other widgets.
                            .then(if (p == 0) Modifier.spot(drag, Spot(Zone.Ladera(0), Spot.END)) else Modifier)
                            .nestedScroll(leftovers)
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        if (p == 0) {
                            FactsStrip(facts, onOpenAbout)
                            board.onPage(0).filterIsInstance<Placed>().forEach { card(it) }
                            Via(apps, home.pinned, onOpenApp, onAppMenu, drag, drop)
                        } else {
                            Ladera(p, board.onPage(p), apps, card, onOpenApp, onAppMenu, drag, drop, onShortcut, onShortcutMenu)
                        }
                    }
                }
            }
            if (board.pages > 1) PageDots(board.pages, page)
            SearchPill { onOpenPetate(true) }
            DockCard(apps, home, onOpenApp, onAppMenu, drag, drop) { onOpenPetate(false) }
        }
        // The carried app follows the finger, a little lifted.
        (drag.held as? HeldWidget)?.let { w ->
            val half = with(LocalDensity.current) { Offset(WIDGET_GHOST_W.toPx() / 2, WIDGET_GHOST_H.toPx() / 2) }
            Box(
                Modifier
                    .offset { (drag.finger - rootOrigin - half).round() }
                    .graphicsLayer { alpha = 0.92f }
                    .size(WIDGET_GHOST_W, WIDGET_GHOST_H)
                    .clip(RoundedCornerShape(20.dp))
                    .background(Ink.raised)
                    .border(1.5.dp, Ink.primary, RoundedCornerShape(20.dp)),
                contentAlignment = Alignment.Center,
            ) { Text(w.label, style = Type.small.copy(color = Ink.text), maxLines = 1) }
        }
        (drag.held as? Held)?.let { h ->
            val half = with(LocalDensity.current) { (TILE / 2).toPx() }
            Box(
                Modifier
                    .offset { (drag.finger - rootOrigin - Offset(half, half)).round() }
                    .graphicsLayer { scaleX = 1.12f; scaleY = 1.12f; alpha = 0.92f }
                    .size(TILE)
                    .clip(RoundedCornerShape(TILE / 3))
                    .background(Ink.raised)
                    .border(1.5.dp, Ink.primary, RoundedCornerShape(TILE / 3)),
                contentAlignment = Alignment.Center,
            ) { AppFace(h.app, h.tone) }
        }
    }
}

private const val EDGE_WAIT_MS = 500L
private val WIDGET_GHOST_W = 168.dp
private val WIDGET_GHOST_H = 72.dp

/** A widget's hold, as the camp handles it: lift onto the board, follow the finger, then land or open its card. */
private class CardGrip(
    private val drag: DragBoard,
    private val cargo: HeldWidget,
    private val onMenu: () -> Unit,
    private val onDrop: (Int, Zone, Int) -> Unit,
) : Grip {
    var origin = Offset.Zero

    override fun lift(x: Float, y: Float) = drag.pick(cargo, origin + Offset(x, y))
    override fun move(dx: Float, dy: Float) = drag.move(Offset(dx, dy))
    override fun cancel() = drag.cancel()
    override fun land(moved: Boolean) {
        if (!moved) { drag.cancel(); onMenu(); return }
        drag.release()?.let { (_, spot) -> onDrop(cargo.id, spot.zone, spot.index) }
    }
}

/** A home tile that can be carried: its spot on the board, coral when a carried app would land on it, faded while lifted. */
@Composable
private fun CarriedTile(
    app: InstalledApp,
    zone: Zone,
    index: Int,
    drag: DragBoard,
    tone: Color,
    background: Color,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    onDrop: (Held, Spot) -> Unit,
    modifier: Modifier = Modifier,
    badge: String? = null,
    tile: androidx.compose.ui.unit.Dp = 56.dp,
    labelColor: Color = Ink.text,
) {
    val spot = Spot(zone, index)
    val lifted = (drag.held as? Held)?.let { it.app.packageName == app.packageName && it.from == zone } == true
    AppTile(
        label = app.label,
        background = background,
        border = if (drag.target == spot && !lifted) Ink.primary else Ink.field,
        badge = badge,
        tile = tile,
        labelColor = labelColor,
        onClick = { onOpenApp(app.packageName) },
        dot = app.packageName in LocalDots.current,
        modifier = modifier.spot(drag, spot).graphicsLayer { alpha = if (lifted) 0.3f else 1f },
        gestures = Modifier.carriable(drag, Held(app, zone, tone), app.label, { onOpenApp(app.packageName) }, { onAppMenu(app.packageName) }, onDrop),
    ) { AppFace(app, tone) }
}

/**
 * A ladera: what you put there, in order. Widgets as cards, apps in rows of four between them.
 */
@Composable
private fun Ladera(
    page: Int,
    items: List<Item>,
    apps: List<InstalledApp>,
    card: @Composable (Placed) -> Unit,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    drag: DragBoard,
    onDrop: (Held, Spot) -> Unit,
    onShortcut: (Pinned) -> Unit,
    onShortcutMenu: (Pinned) -> Unit,
) {
    val byPackage = apps.associateBy { it.packageName }
    // Consecutive apps and shortcuts form one block, so they share rows; each widget is a block of its own.
    val blocks = mutableListOf<Any>()
    items.forEach { item ->
        when (item) {
            is Placed -> blocks += item
            is Shelved, is Pinned -> {
                val pkg = if (item is Shelved) item.packageName else (item as Pinned).packageName
                if (pkg !in byPackage) return@forEach
                @Suppress("UNCHECKED_CAST")
                (blocks.lastOrNull() as? MutableList<Item>)?.add(item) ?: blocks.add(mutableListOf(item))
            }
        }
    }
    blocks.forEach { block ->
        if (block is Placed) card(block)
        else {
            @Suppress("UNCHECKED_CAST")
            (block as List<Item>).chunked(4).forEach { row ->
                Row(Modifier.fillMaxWidth()) {
                    row.forEach { item ->
                        when (item) {
                            is Shelved -> {
                                val app = byPackage.getValue(item.packageName)
                                CarriedTile(
                                    app, Zone.Ladera(page), items.indexOf(item), drag,
                                    Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)], Ink.surface, onOpenApp, onAppMenu, onDrop,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            is Pinned -> {
                                val app = byPackage.getValue(item.packageName)
                                AppTile(
                                    label = item.label,
                                    background = Ink.surface,
                                    border = Ink.field,
                                    badge = "↗",
                                    onClick = { onShortcut(item) },
                                    onLongClick = { onShortcutMenu(item) },
                                    modifier = Modifier.weight(1f).spot(drag, Spot(Zone.Ladera(page), items.indexOf(item))),
                                ) { AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]) }
                            }
                            is Placed -> Unit
                        }
                    }
                    repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
    // The rest of the ladera takes a carried app at its end.
    Box(Modifier.fillMaxWidth().heightIn(min = 96.dp).spot(drag, Spot(Zone.Ladera(page), Spot.END))) {
        Text("Mantén pulsado un widget o una app para traerlos a esta ladera.", style = Type.small)
    }
}

/** Where you are: the Campamento's mark and one per ladera; the current one is a coral bar. */
@Composable
private fun PageDots(pages: Int, current: Int) {
    Row(
        Modifier
            .fillMaxWidth()
            .semantics { contentDescription = if (current == 0) "Campamento, página 1 de $pages" else "Ladera $current, página ${current + 1} de $pages" },
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
    ) {
        repeat(pages) { p ->
            Box(
                Modifier
                    .height(6.dp)
                    .width(if (p == current) 18.dp else 6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(if (p == current) Ink.primary else Ink.borderControl),
            )
        }
    }
}

/**
 * A placed widget, drawn by its app inside a vivac card shape. Holding it and letting go opens its card; holding and
 * moving carries it. It is also a spot: something carried onto it lands in its place.
 */
@Composable
private fun WidgetCard(
    id: Int,
    rows: Int,
    heightDp: Int,
    widgetView: (Context, Int, Float, Int, Grip) -> View?,
    grip: CardGrip,
    drag: DragBoard,
    spot: Spot,
) {
    val lifted = (drag.held as? HeldWidget)?.id == id
    BoxWithConstraints(
        Modifier
            .fillMaxWidth()
            .height(heightDp.dp)
            .spot(drag, spot)
            .onGloballyPositioned { grip.origin = it.positionInRoot() }
            .graphicsLayer { alpha = if (lifted) 0.3f else 1f }
            .clip(RoundedCornerShape(24.dp))
            .background(Ink.surface)
            .border(if (drag.target == spot && !lifted) 1.5.dp else 1.dp, if (drag.target == spot && !lifted) Ink.primary else Ink.field, RoundedCornerShape(24.dp)),
    ) {
        val width = maxWidth.value
        // key(id, rows): a new widget, or a new size, gets a fresh host view laid out for it.
        key(id, rows) {
            AndroidView(
                factory = { ctx -> widgetView(ctx, id, width, rows, grip) ?: android.widget.Space(ctx) },
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
private fun Header(title: String, onOpenSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Type.cota, modifier = Modifier.weight(1f).semantics { heading() })
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
private fun Via(
    apps: List<InstalledApp>,
    pinned: List<String>,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    drag: DragBoard,
    onDrop: (Held, Spot) -> Unit,
) {
    val byPackage = apps.associateBy { it.packageName }
    val shown = pinned.mapNotNull { byPackage[it] }
    if (shown.isEmpty()) {
        // No route yet: while an app is carried, offer the place where it would start.
        if (drag.held is Held) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(96.dp)
                    .spot(drag, Spot(Zone.Via, Spot.END))
                    .border(1.5.dp, if (drag.target?.zone == Zone.Via) Ink.primary else Ink.borderControl, RoundedCornerShape(24.dp)),
                contentAlignment = Alignment.Center,
            ) { Text("Suelta aquí para empezar la vía", style = Type.small) }
        }
        return
    }
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
                .spot(drag, Spot(Zone.Via, Spot.END))
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
                            CarriedTile(
                                app, Zone.Via, index, drag, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)], Ink.surface,
                                onOpenApp, onAppMenu, onDrop, modifier = Modifier.weight(1f), badge = Route.pitch(index), tile = TILE,
                            )
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
private fun DockCard(
    apps: List<InstalledApp>,
    home: Home,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    drag: DragBoard,
    onDrop: (Held, Spot) -> Unit,
    onOpenPetate: () -> Unit,
) {
    val byPackage = apps.associateBy { it.packageName }
    val slots = Dock.pick(byPackage.keys, home.dock, home.dockChosen)
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
        Row(Modifier.fillMaxWidth().spot(drag, Spot(Zone.Dock, Spot.END))) {
            slots.forEachIndexed { i, slot ->
                when (slot) {
                    is DockSlot.App -> {
                        val app = byPackage.getValue(slot.packageName)
                        val deep = app.packageName == "com.termux"
                        CarriedTile(
                            app, Zone.Dock, i, drag, if (deep) Ink.ok else Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)],
                            if (deep) Ink.deep else Ink.field, onOpenApp, onAppMenu, onDrop, modifier = Modifier.weight(1f),
                        )
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
