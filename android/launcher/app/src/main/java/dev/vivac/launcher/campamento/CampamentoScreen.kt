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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.geometry.Size
import androidx.compose.animation.core.animateDecay
import kotlinx.coroutines.launch
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.verticalDrag
import androidx.compose.foundation.gestures.awaitVerticalTouchSlopOrCancellation
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.foundation.combinedClickable
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
import kotlin.math.roundToInt
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.animation.core.animateFloat
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
import dev.vivac.launcher.apps.LocalCounts
import dev.vivac.launcher.apps.LocalDots
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.petate.Pack
import dev.vivac.launcher.theme.AppTile
import dev.vivac.launcher.theme.BADGE_OVERHANG
import dev.vivac.launcher.theme.Contours
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.widgets.Grip
import dev.vivac.launcher.widgets.Step
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.testTag
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
    onEditWidget: (Int) -> Unit,
    onCampMenu: () -> Unit,
    onDrop: (packageName: String, from: Zone, to: Zone, index: Int) -> Unit = { _, _, _, _ -> },
    drag: DragBoard = remember { DragBoard() },
    onWidgetDrop: (id: Int, to: Zone, index: Int) -> Unit = { _, _, _ -> },
    widgetLabel: (Int) -> String = { "widget" },
    onShortcut: (Pinned) -> Unit = {},
    onShortcutMenu: (Pinned) -> Unit = {},
    locked: Boolean = false,
    onDoubleTap: () -> Unit = {},
    wallpaper: Boolean = false,
    /** The night veil over the wallpaper, 0..1. */
    veil: Float = 0.62f,
    onTwoFinger: (dev.vivac.launcher.core.TwoFinger) -> Unit = {},
    /** Shared with the tiles' flicks, so one gesture is never two. */
    twoFingerState: TwoFingerState = remember { TwoFingerState() },
    onOpenFolder: (String) -> Unit = {},
    onSwipeUp: () -> Unit = { onOpenPetate(false) },
    onSwipeDown: () -> Unit = onShowNotifications,
    onMoveItem: (Item, Zone, Int) -> Unit = { _, _, _ -> },
    editing: Int? = null,
    widgetRows: (Int) -> Int = { 0 },
    onResizeWidget: (id: Int, delta: Int) -> Unit = { _, _ -> },
    onStopEditing: () -> Unit = {},
    onAddApps: () -> Unit = {},
    tintWidgets: Boolean = true,
    /** vivac's own widgets (negative ids), drawn by vivac at the rows given. */
    vivacWidget: @Composable (id: Int, rows: Int) -> Unit = { _, _ -> },
    /** A widget and the ones stacked under it, top first. */
    stackOf: (Int) -> List<Int> = { listOf(it) },
    onStack: (Int) -> Unit = {},
    onUnstack: (top: Int, id: Int) -> Unit = { _, _ -> },
    onRemoveWidget: (Int) -> Unit = {},
    /** Apps with notices, newest first: their glyphs sit top left. */
    noticeApps: List<InstalledApp> = emptyList(),
    /** vivac's shade (Android's when vivac may not read notifications). */
    onOpenAvisos: () -> Unit = onShowNotifications,
    status: PhoneStatus = PhoneStatus(),
) {
    drag.locked = locked
    val dp = LocalDensity.current.density
    val drop: (Held, Spot) -> Unit = { h, spot -> onDrop(h.app.packageName, h.from, spot.zone, spot.index) }
    var rootOrigin by remember { mutableStateOf(Offset.Zero) }
    // The settings button's centre on screen: the summit of the rings and the source of the beam.
    var lamp by remember { mutableStateOf<Offset?>(null) }
    val currentPage by rememberUpdatedState(page)
    // Every ladera in use, and one more past the last, empty, to start a new one.
    val shownPages = board.pages + 1
    val pageCount by rememberUpdatedState(shownPages)
    // Holding a carried thing at the left or right edge for a moment turns the page, once per visit to the edge.
    LaunchedEffect(drag.held) {
        if (drag.held == null) return@LaunchedEffect
        val turn = EdgeTurn()
        while (true) {
            delay(EDGE_WAIT_MS)
            val dir = turn.check(drag.finger.x, drag.screen.left, drag.screen.right, edge = 28f * dp)
            if (dir != 0) onPage((currentPage + dir).coerceIn(0, pageCount - 1))
        }
    }
    val onSwipe: (Swipe) -> Unit = { s ->
        // A two-finger gesture is reported on its own; its fingers do not swipe as well.
        if (!twoFingerState.active) when (s) {
            Swipe.DOWN -> onSwipeDown()
            Swipe.UP -> onSwipeUp()
            Swipe.NONE -> Unit
        }
    }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    Box(
        Modifier
            .fillMaxSize()
            // Over the phone's wallpaper, a night veil keeps the camp readable.
            .background(if (wallpaper) Ink.deep.copy(alpha = veil) else Ink.deep)
            .onGloballyPositioned { drag.screen = it.boundsInRoot(); rootOrigin = it.positionInRoot() }
            .twoFingers(twoFingerState, onTwoFinger)
            .swipes({ at -> drag.overWidget(at + rootOrigin) }, onSwipe)
            .pointerInput(Unit) { detectTapGestures(onTap = { onStopEditing() }, onDoubleTap = { onDoubleTap() }, onLongPress = { onCampMenu() }) },
    ) {
        // The rings and the headlamp's beam are centred on the settings button, wherever it is laid out.
        val lampHere = lamp?.minus(rootOrigin)
        Contours(Modifier.fillMaxSize(), color = Ink.surface, centre = lampHere, innerRadius = LAMP_RING)
        Beam(Modifier.fillMaxSize(), lampHere)
        BoxWithConstraints(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp),
        ) {
            // On its side the phone is short: the hour, the facts and the dock go to a column of their own on the
            // left, and the pages get the whole height beside it. Upright, everything is stacked as ever.
            val wide = maxWidth > maxHeight
            val side = maxWidth * 0.34f
            val header: @Composable () -> Unit = { Header(onOpenSettings, noticeApps, onOpenAvisos, status) { lamp = it } }
            val pager = rememberPagerState(initialPage = page) { shownPages }
            // The launcher decides the page (home, a widget sent elsewhere); a swipe tells it where you went.
            LaunchedEffect(page) { if (pager.currentPage != page) pager.animateScrollToPage(page) }
            LaunchedEffect(pager) { snapshotFlow { pager.settledPage }.collect(onPage) }
            val card: @Composable (Placed) -> Unit = { w ->
                val spot = Spot(Zone.Ladera(w.page), board.onPage(w.page).indexOf(w))
                val grip = remember(w.id, w.page) { CardGrip(drag, HeldWidget(w.id, Zone.Ladera(w.page), widgetLabel(w.id)), { onEditWidget(w.id) }, onWidgetDrop) }
                val vivac = w.id < 0
                val height = if (vivac) WidgetSize.heightOf(widgetRows(w.id)) else widgetHeightDp(w.id, w.rows)
                WidgetCard(
                    w.id, w.rows, widgetRows(w.id), height, widgetView, grip, drag, spot, w.id == editing, tintWidgets,
                    own = if (vivac) ({ vivacWidget(w.id, widgetRows(w.id)) }) else null,
                    stack = stackOf(w.id),
                    ownOf = { sid -> if (sid < 0) ({ vivacWidget(sid, widgetRows(w.id)) }) else null },
                    onStack = { onStack(w.id) },
                    onUnstack = { sid -> onUnstack(w.id, sid) },
                    onRemove = onRemoveWidget,
                ) { onResizeWidget(w.id, it) }
            }
            // While something is carried, every page stays composed: the page it came from holds the finger (a
            // widget's own view, a tile's gesture), and tearing it down when the page turns would drop it.
            val pages: @Composable (Modifier) -> Unit = { into -> HorizontalPager(
                pager,
                into,
                pageSpacing = 24.dp,
                verticalAlignment = Alignment.Top,
                beyondViewportPageCount = if (drag.held != null) shownPages else 0,
            ) { p ->
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (p == 0 && !wide) Clock(stamp)
                    if (p >= 1 && board.onPage(p).isEmpty()) NewLadera(p, drag, onAddApps, Modifier.weight(1f))
                    else BoxWithConstraints(Modifier.weight(1f)) {
                    // How tall the page is: a ladera's grid of empty cells reaches down to its bottom.
                    val viewport = maxHeight
                    val scroll = rememberScrollState()
                    var columnOrigin by remember { mutableStateOf(Offset.Zero) }
                    Column(
                        Modifier
                            .fillMaxSize()
                            // The camp takes a carried widget anywhere over it, after its other widgets.
                            .then(if (p == 0) Modifier.spot(drag, Spot(Zone.Ladera(0), Spot.END)) else Modifier)
                            .onGloballyPositioned { columnOrigin = it.positionInRoot() }
                            // Scrolled by vivac's own drag, which leaves a drag that starts on a widget to the widget.
                            .pageDrags(scroll, scope, { at -> drag.overWidget(at + columnOrigin) }, onSwipe)
                            .verticalScroll(scroll, enabled = false),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        if (p == 0) {
                            // The route sits in the middle of the room left under the facts and widgets, with as
                            // much space above it as below, down to the dock.
                            var abovePx by remember { mutableIntStateOf(0) }
                            var routePx by remember { mutableIntStateOf(0) }
                            Column(Modifier.fillMaxWidth().onSizeChanged { abovePx = it.height }, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                                if (!wide) FactsStrip(facts, onOpenAbout)
                                board.onPage(0).filterIsInstance<Placed>().forEach { card(it) }
                            }
                            // Part of the room goes between the route's rows, so they breathe; the rest above and below.
                            val dens = LocalDensity.current
                            val rowCount = Route.rows(home.pinned.count { pkg -> apps.any { it.packageName == pkg } }, 4).size
                            // The gap, in whole pixels, the measured route was laid out with. Kept with routePx so the
                            // rows' own height is exact; a guessed or truncated gap fed the error back into the next
                            // gap and the rows shook by a pixel or two every frame, the lowest ones the most.
                            var routeGapPx by remember { mutableIntStateOf(0) }
                            val basePx = with(dens) { ROW_GAP.roundToPx() }
                            val gaps = with(dens) { (2 * 16).dp.roundToPx() }
                            val viewportPx = with(dens) { viewport.roundToPx() }
                            val joins = (rowCount - 1).coerceAtLeast(0)
                            // The rows' height without any gap: it does not depend on the gap chosen below.
                            val natural = routePx - joins * routeGapPx
                            val room = viewportPx - abovePx - natural - gaps
                            val rowGapPx = if (joins > 0 && routePx > 0 && room > 0) {
                                (basePx + room * 0.5f / joins).roundToInt().coerceAtMost(with(dens) { 56.dp.roundToPx() })
                            } else basePx
                            // Centre the route as it will be with this gap, not as it was last frame.
                            val spare = viewportPx - abovePx - (natural + joins * rowGapPx) - gaps
                            if (spare > 0 && routePx > 0) Spacer(Modifier.height(with(dens) { (spare / 2).toDp() }))
                            Box(
                                Modifier
                                    .fillMaxWidth()
                                    .onSizeChanged { routePx = it.height; routeGapPx = rowGapPx }
                                    .testTag("via"),
                            ) {
                                Via(apps, home.pinned, onOpenApp, onAppMenu, drag, drop, rowGap = with(dens) { rowGapPx.toDp() })
                            }
                        } else {
                            Ladera(p, board.onPage(p), apps, card, onOpenApp, onAppMenu, drag, drop, onShortcut, onShortcutMenu, onOpenFolder, viewport) { c, spot ->
                                if (c is HeldItem) onMoveItem(c.item, spot.zone, spot.index)
                            }
                        }
                    }
                    }
                }
            }
            }
            if (wide) {
                // The bar runs the whole width, as upright; under it the hour and facts on the left, the pages in the
                // middle and the dock as a rail down the right edge, where its apps have room one above the other.
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    header()
                    Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        // The hour and the facts are one block, in the middle of the height: no dead room between them.
                        Column(
                            Modifier.width(side).fillMaxHeight().padding(bottom = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterVertically),
                        ) {
                            Clock(stamp)
                            FactsStrip(facts, onOpenAbout)
                        }
                        Column(Modifier.weight(1f).fillMaxHeight().padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            pages(Modifier.weight(1f))
                            PageDots(shownPages, page)
                        }
                        // Names do not fit a rail: icons only (TalkBack still reads the names).
                        androidx.compose.runtime.CompositionLocalProvider(dev.vivac.launcher.theme.LocalLabels provides false) {
                            DockRail(apps, home, onOpenApp, onAppMenu, drag, drop, Modifier.fillMaxHeight().padding(top = 14.dp, bottom = 12.dp))
                        }
                    }
                }
            } else {
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    header()
                    pages(Modifier.weight(1f))
                    PageDots(shownPages, page)
                    DockCard(apps, home, onOpenApp, onAppMenu, drag, drop)
                }
            }
        }
        // A carried widget follows the finger as a picture of itself, just where the finger took it.
        (drag.held as? HeldWidget)?.takeIf { it.look != null }?.let { w ->
            val size = with(LocalDensity.current) { androidx.compose.ui.unit.DpSize(w.size.width.toDp(), w.size.height.toDp()) }
            androidx.compose.foundation.Image(
                w.look!!,
                contentDescription = null,
                modifier = Modifier
                    .offset { (drag.finger - rootOrigin - w.grab).round() }
                    .size(size)
                    .graphicsLayer { scaleX = 1.03f; scaleY = 1.03f; alpha = 0.92f }
                    .clip(RoundedCornerShape(24.dp))
                    .border(2.dp, Ink.primary, RoundedCornerShape(24.dp))
                    .testTag("widget:ghost"),
            )
        }
        // Anything else carried that is not an app: a card with its name.
        val carriedLabel = when (val c = drag.held) { is HeldWidget -> c.label.takeIf { c.look == null }; is HeldItem -> c.label; else -> null }
        carriedLabel?.let { label ->
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
            ) {
                // Decorative: a copy of the tile under the finger; TalkBack keeps reading the tile itself.
                Text(label, style = Type.small.copy(color = Ink.text), maxLines = 1, modifier = Modifier.clearAndSetSemantics {})
            }
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
/** The settings button's touch target, and the radius of the ring that is its frame. */
private val LAMP_BOX = 44.dp
private val LAMP_RING = 26.dp
private val WIDGET_GHOST_W = 168.dp
private val WIDGET_GHOST_H = 72.dp

/**
 * A widget's hold, as the camp handles it: the long press itself puts the widget into moving and resizing, lifts a
 * picture of it onto the board and lets it follow the finger; letting go lands it, or leaves it where it was to resize.
 */
private class CardGrip(
    private val drag: DragBoard,
    val cargo: HeldWidget,
    val onEdit: () -> Unit,
    val onDrop: (Int, Zone, Int) -> Unit,
) : Grip {
    var origin = Offset.Zero
    var size = androidx.compose.ui.unit.IntSize.Zero

    override fun lift(x: Float, y: Float, look: android.graphics.Bitmap?) {
        onEdit()
        drag.pick(cargo.copy(look = look?.asImageBitmap(), grab = Offset(x, y), size = size), origin + Offset(x, y))
    }
    override fun move(dx: Float, dy: Float) = drag.move(Offset(dx, dy))
    override fun cancel() = drag.cancel()
    override fun land(moved: Boolean) {
        if (!moved) { drag.cancel(); return }
        if (drag.held == null) return
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
        count = LocalCounts.current[app.packageName] ?: 0,
        modifier = modifier
            .spot(drag, spot)
            .onGloballyPositioned { drag.placeTile(app.packageName, zone, it.boundsInRoot()) }
            .graphicsLayer { alpha = if (lifted) 0.3f else 1f },
        gestures = Modifier.carriable(drag, Held(app, zone, tone), app.label, { onOpenApp(app.packageName) }, { onAppMenu(app.packageName) }, onDrop),
    ) { AppFace(app, tone) }
}

/**
 * A ladera: a grid four cells wide, what you put there in order. Widgets take whole rows as cards; apps, shortcuts
 * and folders sit in cells between them, and empty cells (kept, and the free ones down to the bottom of the page)
 * take whatever is let go over them, right there.
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
    onDropApp: (Held, Spot) -> Unit,
    onShortcut: (Pinned) -> Unit,
    onShortcutMenu: (Pinned) -> Unit,
    onOpenFolder: (String) -> Unit,
    viewport: androidx.compose.ui.unit.Dp,
    onDropItem: (Cargo, Spot) -> Unit = { _, _ -> },
) {
    val onDrop: (Cargo, Spot) -> Unit = { c, s -> if (c is Held) onDropApp(c, s) else onDropItem(c, s) }
    val byPackage = apps.associateBy { it.packageName }
    val zone = Zone.Ladera(page)
    // Consecutive cells form one block, so they share rows; each widget is a block of its own. Each cell keeps its
    // place in the ladera's order, which is where something let go over it lands.
    val blocks = mutableListOf<Any>()
    items.forEachIndexed { i, item ->
        when (item) {
            is Placed -> blocks += item
            is Gap, is Shelved, is Pinned, is Folder -> {
                val known = when (item) {
                    is Shelved -> item.packageName in byPackage
                    is Pinned -> item.packageName in byPackage
                    is Folder -> item.apps.any { it in byPackage }
                    else -> true
                }
                // Something whose app is gone shows as an empty cell, so the others keep their cells.
                val cell = IndexedValue(i, if (known) item else Gap(page))
                @Suppress("UNCHECKED_CAST")
                (blocks.lastOrNull() as? MutableList<IndexedValue<Item>>)?.add(cell) ?: blocks.add(mutableListOf(cell))
            }
        }
    }
    val density = LocalDensity.current
    var usedPx by remember { mutableIntStateOf(0) }
    // Every row of apps is one cell tall, so a widget of n rows ends where n rows of apps end.
    val cellHeight = WidgetSize.CELL_DP.dp
    // The grid starts at the top of the page, like any home screen: its first row is always there to put things in,
    // and the free cells fill the room below. (Centring it left dead room above that nothing could land in.)
    Column(Modifier.fillMaxWidth().onSizeChanged { usedPx = it.height }, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        blocks.forEachIndexed { b, block ->
            if (block is Placed) card(block)
            else {
                @Suppress("UNCHECKED_CAST")
                val rows = (block as List<IndexedValue<Item>>).chunked(4)
                rows.forEachIndexed { r, row ->
                    Row(Modifier.fillMaxWidth().heightIn(min = cellHeight)) {
                        row.forEach { (i, item) ->
                            when (item) {
                                is Gap -> EmptyCell(Spot(zone, i), drag, cellHeight, Modifier.weight(1f))
                                is Shelved -> {
                                    val app = byPackage.getValue(item.packageName)
                                    CarriedTile(
                                        app, zone, i, drag,
                                        Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)], Ink.surface, onOpenApp, onAppMenu, onDropApp,
                                        modifier = Modifier.weight(1f),
                                    )
                                }
                                is Pinned -> {
                                    val app = byPackage.getValue(item.packageName)
                                    val spot = Spot(zone, i)
                                    val lifted = (drag.held as? HeldItem)?.item == item
                                    AppTile(
                                        label = item.label,
                                        background = Ink.surface,
                                        border = if (drag.target == spot && !lifted) Ink.primary else Ink.field,
                                        badge = "↗",
                                        onClick = { onShortcut(item) },
                                        onLongClick = { onShortcutMenu(item) },
                                        modifier = Modifier.weight(1f).spot(drag, spot).graphicsLayer { alpha = if (lifted) 0.3f else 1f },
                                        gestures = Modifier.carrying(drag, HeldItem(item, zone, item.label), item.label, { onShortcut(item) }, { onShortcutMenu(item) }, onDrop),
                                    ) { AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]) }
                                }
                                is Folder -> FolderTile(
                                    item, item.apps.mapNotNull { byPackage[it] }, drag, onOpenFolder,
                                    Modifier.weight(1f), page, i, onDrop,
                                )
                                is Placed -> Unit
                            }
                        }
                        // The last row of the ladera goes on in free cells; a row before a widget just ends.
                        val last = b == blocks.lastIndex && r == rows.lastIndex
                        repeat(4 - row.size) { k ->
                            if (last) EmptyCell(Spot(zone, items.size + k), drag, cellHeight, Modifier.weight(1f))
                            else Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
    // Free rows of cells down to the bottom of the page, numbered on from the last cell.
    @Suppress("UNCHECKED_CAST")
    val tail = (blocks.lastOrNull() as? List<Any>)?.let { (4 - it.size % 4) % 4 } ?: 0
    val gap = WidgetSize.GAP_DP.dp
    val free = with(density) {
        val room = viewport.toPx() - usedPx - gap.toPx()
        (room / (cellHeight.toPx() + gap.toPx())).toInt().coerceAtLeast(0)
    }
    repeat(free) { r ->
        Row(Modifier.fillMaxWidth()) {
            repeat(4) { c -> EmptyCell(Spot(zone, items.size + tail + r * 4 + c), drag, cellHeight, Modifier.weight(1f)) }
        }
    }
    // The rest of the ladera takes a carried thing at its end. It only takes room while something is carried,
    // so a full ladera has no blank space under it to scroll into.
    Box(Modifier.fillMaxWidth().height(if (drag.held != null) 96.dp else 0.dp).spot(drag, Spot(zone, Spot.END)))
}

/** A ladera's empty cell: nothing to see, but outlined while something is carried, coral when it would land here. */
@Composable
private fun EmptyCell(spot: Spot, drag: DragBoard, height: androidx.compose.ui.unit.Dp, modifier: Modifier) {
    val carrying = drag.held != null
    val target = drag.target == spot
    Box(
        modifier
            .height(height)
            .spot(drag, spot)
            .testTag("cell:${(spot.zone as Zone.Ladera).page}:${spot.index}")
            .padding(6.dp)
            .then(
                if (!carrying) Modifier
                else Modifier.border(if (target) 2.dp else 1.dp, if (target) Ink.primary else Ink.field, RoundedCornerShape(18.dp)),
            ),
    )
}

/** The empty ladera past the last one: a plus in the middle adds apps to it; anything carried here lands on it. */
@Composable
private fun NewLadera(page: Int, drag: DragBoard, onAdd: () -> Unit, modifier: Modifier) {
    Column(
        modifier.fillMaxWidth().spot(drag, Spot(Zone.Ladera(page), Spot.END)),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .size(88.dp)
                .clip(CircleShape)
                .background(Ink.raised)
                .border(1.5.dp, Ink.primary, CircleShape)
                .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onAdd)
                .semantics { contentDescription = "Añadir apps a esta ladera" },
            contentAlignment = Alignment.Center,
        ) { LineIcon(Glyph.PLUS, Ink.primary, 36.dp) }
        Spacer(Modifier.height(16.dp))
        Text(
            "Toca + para añadir apps, o mantén pulsado un widget o una app para traerlos aquí.",
            style = Type.small,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.padding(horizontal = 24.dp),
        )
    }
}

/** A folder: up to four of its apps' glyphs in a two-by-two tile; a carried app dropped on it goes in. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun FolderTile(
    folder: Folder,
    apps: List<InstalledApp>,
    drag: DragBoard,
    onOpen: (String) -> Unit,
    modifier: Modifier,
    page: Int,
    index: Int,
    onDrop: (Cargo, Spot) -> Unit,
) {
    val spot = Spot(Zone.Folder(folder.id), 0)
    val lifted = (drag.held as? HeldItem)?.item == folder
    Column(
        modifier
            .spot(drag, spot)
            // Its place on the ladera too, so something carried can land beside it.
            .spot(drag, Spot(Zone.Ladera(page), index))
            .graphicsLayer { alpha = if (lifted) 0.3f else 1f }
            .clip(RoundedCornerShape(18.dp))
            .carrying(drag, HeldItem(folder, Zone.Ladera(page), folder.name), "la carpeta ${folder.name}", { onOpen(folder.id) }, { onOpen(folder.id) }, onDrop)
            .semantics(mergeDescendants = true) { contentDescription = "Carpeta ${folder.name}, ${apps.size} apps" },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier
                .size(TILE)
                .clip(RoundedCornerShape(TILE / 3))
                .background(Ink.raised)
                .border(if (drag.target == spot) 1.5.dp else 1.dp, if (drag.target == spot) Ink.primary else Ink.field, RoundedCornerShape(TILE / 3))
                .padding(7.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                apps.take(4).chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                        row.forEach { app ->
                            Box(Modifier.size(19.dp), contentAlignment = Alignment.Center) {
                                val glyph = dev.vivac.launcher.apps.Glyphs.of(app.packageName)
                                val tone = Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]
                                if (glyph != null) LineIcon(glyph, tone, 17.dp) else Text(Pack.monogram(app), style = Type.cota.copy(fontSize = 8.sp, color = tone))
                            }
                        }
                    }
                }
            }
        }
        Text(folder.name, style = Type.small.copy(color = Ink.text), maxLines = 1)
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
 * A placed widget, drawn by its app inside a vivac card shape. Holding it puts it into moving and resizing: moving
 * the finger carries it, and while [editing] a bar on it changes its height (its buttons, or dragging the bar).
 * It is also a spot: something carried onto it lands in its place.
 */
@Composable
private fun WidgetCard(
    id: Int,
    rows: Int,
    /** The rows it shows at: the ones you chose, else its own. */
    shownRows: Int,
    heightDp: Int,
    widgetView: (Context, Int, Float, Int, Grip) -> View?,
    grip: CardGrip,
    drag: DragBoard,
    spot: Spot,
    editing: Boolean,
    tint: Boolean,
    /** A widget vivac draws itself: carried with a hold like a tile, and not a view holding the finger. */
    own: (@Composable () -> Unit)? = null,
    /** This widget and the ones stacked under it; more than one makes a stack, swiped through. */
    stack: List<Int> = listOf(id),
    ownOf: (Int) -> (@Composable () -> Unit)? = { null },
    onStack: () -> Unit = {},
    onUnstack: (Int) -> Unit = {},
    /** Removes the widget shown: the top, or the one swiped to in a stack. */
    onRemove: (Int) -> Unit = {},
    onResize: (Int) -> Unit,
) {
    androidx.compose.runtime.DisposableEffect(drag, id) { onDispose { drag.forgetWidget(id) } }
    val lifted = (drag.held as? HeldWidget)?.id == id
    // The widget is drawn as it is, with vivac's corners and no frame of its own; coral marks it only while it is
    // being resized, or as the place something carried would land.
    val marked = !lifted && (editing || drag.target == spot)
    BoxWithConstraints(
        Modifier
            .fillMaxWidth()
            .height(heightDp.dp)
            .spot(drag, spot)
            // Only an app's widget keeps vertical drags for its own list; vivac's own let the page have them.
            .onGloballyPositioned { grip.origin = it.positionInRoot(); grip.size = it.size; if (own == null) drag.placeWidget(id, it.boundsInRoot()) }
            .then(
                if (own != null) Modifier.carrying(drag, grip.cargo, grip.cargo.label, onOpen = {}, onMenu = grip.onEdit, onDrop = { _, s -> grip.onDrop(id, s.zone, s.index) })
                else Modifier,
            )
            .testTag("widget:$id")
            .graphicsLayer { alpha = if (lifted) 0.3f else 1f }
            .clip(RoundedCornerShape(24.dp))
            .then(if (marked) Modifier.border(2.dp, Ink.primary, RoundedCornerShape(24.dp)) else Modifier),
    ) {
        val width = maxWidth.value
        val body: @Composable (Int) -> Unit = { sid ->
            val drawn = if (sid == id) own else ownOf(sid)
            if (drawn != null) drawn()
            // key(id, rows): a new widget, or a new size, gets a fresh host view laid out for it.
            else key(sid, rows) {
            AndroidView(
                factory = { ctx -> widgetView(ctx, sid, width, rows, grip) ?: android.widget.Space(ctx) },
                modifier = Modifier.fillMaxSize(),
                // The tint is drawn on the widget's own layer, so it costs one pass, not one per frame.
                update = { v ->
                    if (tint) v.setLayerType(View.LAYER_TYPE_HARDWARE, android.graphics.Paint().apply { colorFilter = android.graphics.ColorMatrixColorFilter(dev.vivac.launcher.widgets.WidgetColors.tint()) })
                    else v.setLayerType(View.LAYER_TYPE_NONE, null)
                },
            )
            }
        }
        var current by remember(stack) { mutableStateOf(id) }
        if (stack.size > 1) {
            val pages = androidx.compose.foundation.pager.rememberPagerState { stack.size }
            LaunchedEffect(pages, stack) { snapshotFlow { pages.currentPage }.collect { current = stack[it.coerceIn(0, stack.lastIndex)] } }
            HorizontalPager(pages, Modifier.fillMaxSize().testTag("stack:$id")) { p -> body(stack[p]) }
            Row(Modifier.align(Alignment.TopCenter).padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                stack.indices.forEach { i ->
                    Box(Modifier.size(5.dp).clip(androidx.compose.foundation.shape.CircleShape).background(if (i == pages.currentPage) Ink.text else Ink.borderControl))
                }
            }
        } else body(id)
        if (editing && !lifted) {
            Row(Modifier.align(Alignment.TopEnd).padding(8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (current != id) StackChip("Sacar de la pila") { onUnstack(current) }
                StackChip("Apilar otro", onStack)
                StackChip("Quitar") { onRemove(current) }
            }
            ResizeBar(shownRows, onResize, Modifier.align(Alignment.BottomCenter).padding(bottom = 8.dp))
        }
    }
}

@Composable
private fun StackChip(text: String, onClick: () -> Unit) {
    Box(
        Modifier
            .height(32.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.raised)
            .border(1.dp, Ink.primary, RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, style = Type.small.copy(color = Ink.text)) }
}

/**
 * The height of a widget being resized: shorter, its rows, taller. Dragging the bar up or down changes it a row
 * at a time, as the finger passes half a row, so the widget's edge keeps up with the finger.
 */
@Composable
private fun ResizeBar(rows: Int, onResize: (Int) -> Unit, modifier: Modifier) {
    val resize by rememberUpdatedState(onResize)
    Row(
        modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Ink.raised)
            .border(1.5.dp, Ink.primary, RoundedCornerShape(999.dp))
            .pointerInput(Unit) {
                val row = WidgetSize.ROW_DP.dp.toPx()
                var pull = 0f
                detectVerticalDragGestures(onDragStart = { pull = 0f }) { change, dy ->
                    change.consume()
                    pull += dy
                    while (pull >= row / 2) { resize(+1); pull -= row }
                    while (pull <= -row / 2) { resize(-1); pull += row }
                }
            }
            .padding(4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Step(Glyph.MINUS, "Más bajo", enabled = rows > 1) { onResize(-1) }
        Text(if (rows == 1) "1 fila" else "$rows filas", style = Type.figure.copy(fontSize = 16.sp), modifier = Modifier.width(64.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Step(Glyph.PLUS, "Más alto", enabled = rows < WidgetSize.MAX_ROWS) { onResize(+1) }
    }
}

/**
 * A page's vertical drags: they scroll it, and what it cannot scroll (already at its top or bottom) counts as a
 * swipe, as anywhere else on the camp. A drag that starts on a widget ([onWidget]) is left alone, so the widget's
 * own list scrolls.
 */
private fun Modifier.pageDrags(
    scroll: androidx.compose.foundation.ScrollState,
    scope: kotlinx.coroutines.CoroutineScope,
    onWidget: (Offset) -> Boolean,
    onSwipe: (Swipe) -> Unit,
): Modifier = pointerInput(scroll) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        if (onWidget(down.position)) return@awaitEachGesture
        val tracker = VelocityTracker().apply { addPosition(down.uptimeMillis, down.position) }
        var leftover = 0f
        val move = { dy: Float -> leftover += dy + scroll.dispatchRawDelta(-dy) }
        val start = awaitVerticalTouchSlopOrCancellation(down.id) { change, over -> change.consume(); move(over) } ?: return@awaitEachGesture
        tracker.addPosition(start.uptimeMillis, start.position)
        verticalDrag(start.id) { change ->
            move(change.positionChange().y)
            tracker.addPosition(change.uptimeMillis, change.position)
            change.consume()
        }
        val velocity = tracker.calculateVelocity().y
        onSwipe(Swipe.classify(dyDp = leftover / density, velocityDp = velocity / density))
        // The page goes on scrolling for a moment, slowing down, as a flung list does.
        scope.launch {
            var last = 0f
            androidx.compose.animation.core.AnimationState(0f, -velocity).animateDecay(androidx.compose.animation.core.exponentialDecay<Float>()) {
                val step = value - last
                last = value
                if (kotlin.math.abs(scroll.dispatchRawDelta(step) - step) > 0.5f) cancelAnimation()
            }
        }
    }
}

/**
 * Vertical swipes anywhere on the Campamento; taps on cards and tiles still go through, and a drag that starts on
 * a widget ([onWidget]) is the widget's.
 */
private fun Modifier.swipes(onWidget: (Offset) -> Boolean, onSwipe: (Swipe) -> Unit): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        if (onWidget(down.position)) return@awaitEachGesture
        val tracker = VelocityTracker().apply { addPosition(down.uptimeMillis, down.position) }
        var dy = 0f
        val start = awaitVerticalTouchSlopOrCancellation(down.id) { change, over -> change.consume(); dy += over } ?: return@awaitEachGesture
        tracker.addPosition(start.uptimeMillis, start.position)
        verticalDrag(start.id) { change ->
            dy += change.positionChange().y
            tracker.addPosition(change.uptimeMillis, change.position)
            change.consume()
        }
        onSwipe(Swipe.classify(dyDp = dy / density, velocityDp = tracker.calculateVelocity().y / density))
    }
}

/** Motif 2, la frontal: the headlamp's beam falling across the camp from the settings corner, swaying gently. */
@Composable
private fun Beam(modifier: Modifier, origin: Offset?) {
    if (origin == null) return
    val moving = Motion.allowed(LocalContext.current)
    // The beam is drawn once; the sway and the glow are its layer's rotation and alpha, applied by the render thread.
    val phase = if (moving) {
        dev.vivac.launcher.theme.rememberLoop(Motion.LAMP_PERIOD_MS)
    } else null
    Canvas(
        modifier.graphicsLayer {
            val t = phase?.value ?: 0f
            val f = Motion.flare(t)
            rotationZ = Motion.sway(t)
            // Reaching forward: a touch longer and brighter for a moment.
            scaleX = 1f + 0.07f * f
            scaleY = 1f + 0.07f * f
            alpha = ((Motion.glow(t) + 0.1f * f) / Motion.GLOW_MAX).coerceAtMost(1.3f)
            // It sways about the lamp itself, the centre of the smallest ring.
            transformOrigin = androidx.compose.ui.graphics.TransformOrigin(origin.x / size.width, origin.y / size.height)
            // One path: no offscreen buffer needed to fade it.
            compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.ModulateAlpha
        },
    ) {
        val (a, b) = dev.vivac.launcher.theme.beamEdges(origin, size.width, size.height)
        val beam = Path().apply {
            moveTo(origin.x, origin.y)
            lineTo(a.x, a.y)
            lineTo(b.x, b.y)
            close()
        }
        val far = Offset((a.x + b.x) / 2, (a.y + b.y) / 2)
        drawPath(
            beam,
            Brush.linearGradient(
                0f to Ink.primary.copy(alpha = Motion.GLOW_MAX),
                0.35f to Ink.primary.copy(alpha = 0.06f),
                0.6f to Color.Transparent,
                start = origin,
                end = far,
            ),
        )
    }
    // The faintest dazzle as it reaches forward: a warm glow from the lamp over the whole camp, a few percent at most.
    // It is only there while it flares, a second at each end of the swing: a full-screen layer at alpha 0 still cost
    // the GPU a pass every frame.
    val flaring by remember(phase) { androidx.compose.runtime.derivedStateOf { Motion.flare(phase?.value ?: 0f) > 0f } }
    if (flaring) Canvas(
        modifier.graphicsLayer {
            alpha = 0.06f * Motion.flare(phase?.value ?: 0f)
            compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.ModulateAlpha
        },
    ) {
        drawRect(Brush.radialGradient(listOf(Ink.text, Color.Transparent), center = origin, radius = size.width * 1.1f))
    }
}

@Composable
private fun Header(
    onOpenSettings: () -> Unit,
    noticeApps: List<InstalledApp> = emptyList(),
    onNotices: () -> Unit = {},
    status: PhoneStatus = PhoneStatus(),
    onPlaced: (Offset) -> Unit = {},
) {
    // No page name: the dots below say where you are. Top left, the apps with notices, as a status bar would; by
    // the lamp, the connections.
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) { if (noticeApps.isNotEmpty()) NoticeGlyphs(noticeApps, onNotices) }
        // The others keep out of the lamp's ring: it reaches LAMP_RING past the button's own box.
        Connections(status, Modifier.padding(end = LAMP_RING - LAMP_BOX / 2 + 10.dp))
        // The headlamp itself: a bar icon like the others, but coral and alone at the centre of its own ring, where
        // the rings and the beam start. The box is the touch target; its ring, in thin coral, is what marks it out.
        Box(
            Modifier
                .size(LAMP_BOX)
                .onGloballyPositioned { onPlaced(it.boundsInRoot().center) }
                .drawBehind { drawCircle(Ink.accentText, LAMP_RING.toPx(), style = androidx.compose.ui.graphics.drawscope.Stroke(1.dp.toPx())) }
                .clip(CircleShape)
                .clickable(role = Role.Button, onClickLabel = "Abrir ajustes", onClick = onOpenSettings)
                .semantics { contentDescription = "Ajustes del sistema" },
            contentAlignment = Alignment.Center,
        ) { LineIcon(Glyph.SLIDERS, Ink.accentText, 18.dp) }
    }
}

/** The hour, as big as the night allows, and the date stacked like a summit marker. */
@Composable
private fun Clock(stamp: String) {
    val time = stamp.substringAfter(" · ", stamp)
    val day = stamp.substringBefore(" · ", "").split(" ")
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        FitHour(time, Modifier.weight(1f))
        if (day.size == 3) {
            Column(Modifier.padding(bottom = 10.dp), horizontalAlignment = Alignment.End) {
                Text(day[0], style = Type.mono)
                Text(day[1], style = Type.figure.copy(fontSize = 22.sp, lineHeight = 26.sp))
                Text(day[2], style = Type.mono)
            }
        }
    }
}

/** Tailscale when it is up, Wi-Fi and mobile signal in bars: lit as strong as they are, the rest faint. */
@Composable
private fun Connections(status: PhoneStatus, modifier: Modifier) {
    Row(
        modifier.semantics(mergeDescendants = true) { contentDescription = status.spoken },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (status.tailscale) {
            // Tailscale's mark of nine dots, drawn in vivac's line: the middle row lit.
            Canvas(Modifier.size(16.dp)) {
                val step = size.width / 3
                for (r in 0..2) for (c in 0..2) {
                    drawCircle(if (r == 1 || (r == 2 && c == 1)) Ink.text else Ink.borderControl, step * 0.18f, Offset(step * (c + 0.5f), step * (r + 0.5f)))
                }
            }
        }
        status.wifi?.let { level ->
            Canvas(Modifier.size(width = 18.dp, height = 14.dp)) {
                val w = 1.6.dp.toPx()
                val centre = Offset(size.width / 2, size.height)
                (1..3).forEach { arc ->
                    val r = size.height * arc / 3.2f
                    drawArc(
                        if (level >= arc + 1 || (arc == 3 && level >= 4)) Ink.text else Ink.borderControl,
                        startAngle = 225f, sweepAngle = 90f, useCenter = false,
                        topLeft = Offset(centre.x - r, centre.y - r), size = Size(2 * r, 2 * r),
                        style = androidx.compose.ui.graphics.drawscope.Stroke(w, cap = androidx.compose.ui.graphics.StrokeCap.Round),
                    )
                }
                drawCircle(if (level >= 1) Ink.text else Ink.borderControl, w, Offset(centre.x, centre.y - w))
            }
        }
        Canvas(Modifier.size(width = 16.dp, height = 14.dp)) {
            val bar = size.width / 5.5f
            (0..3).forEach { i ->
                val h = size.height * (i + 1) / 4f
                drawRoundRect(
                    if ((status.cell ?: 0) > i) Ink.text else Ink.borderControl,
                    Offset(i * bar * 1.5f, size.height - h), Size(bar, h), androidx.compose.ui.geometry.CornerRadius(bar / 3),
                )
            }
        }
    }
}

/** The glyphs of the apps with notices, newest first: six at most, then how many more. A tap opens the shade. */
@Composable
private fun NoticeGlyphs(apps: List<InstalledApp>, onClick: () -> Unit) {
    val names = apps.map { it.label }
    Row(
        Modifier
            .clip(RoundedCornerShape(999.dp))
            .clickable(role = Role.Button, onClickLabel = "Ver los avisos", onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = "Avisos de " + if (names.size == 1) names.single() else names.dropLast(1).joinToString(", ") + " y " + names.last()
            }
            .padding(horizontal = 4.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        apps.take(6).forEach { app ->
            Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
                androidx.compose.runtime.CompositionLocalProvider(dev.vivac.launcher.apps.LocalIconChoice provides dev.vivac.launcher.apps.IconChoice(dev.vivac.launcher.core.IconStyle.GLYPHS, null)) {
                    Box(Modifier.graphicsLayer { scaleX = 0.66f; scaleY = 0.66f }) { AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]) }
                }
            }
        }
        if (apps.size > 6) Text("+${apps.size - 6}", style = Type.cota.copy(fontSize = 11.sp))
    }
}

/**
 * The hour on one line, as big as fits beside the date: wide hours (00:00, 12:00) shrink a little rather than wrap
 * or run under it.
 */
@Composable
private fun FitHour(time: String, modifier: Modifier) {
    BoxWithConstraints(modifier) {
        val measurer = androidx.compose.ui.text.rememberTextMeasurer()
        val room = constraints.maxWidth
        // Upright the hour has all the height it wants; on its side it also keeps within the room it is given.
        val tall = if (constraints.hasBoundedHeight) constraints.maxHeight else Int.MAX_VALUE
        val style = remember(time, room, tall) {
            var size = Type.hour.fontSize.value
            fun fits(sp: Float) = measurer.measure(time, Type.hour.copy(fontSize = sp.sp, lineHeight = sp.sp), maxLines = 1, softWrap = false).size
                .let { it.width <= room && it.height <= tall }
            while (size > 24f && !fits(size)) size *= 0.96f
            Type.hour.copy(fontSize = size.sp, lineHeight = size.sp)
        }
        Text(time, style = style, maxLines = 1, softWrap = false)
    }
}

/** Battery and free space as map annotations between two hairlines. */
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
        // The battery's icon says its level and whether it is charging; the number sits beside it.
        Column(
            Modifier
                .weight(1f)
                .padding(start = 10.dp, top = 10.dp, bottom = 10.dp, end = 6.dp)
                .semantics(mergeDescendants = true) {
                    contentDescription = "Batería al ${facts.batteryPercent} %" + if (facts.charging) ", cargando" else ""
                },
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("BATERÍA", style = Type.cota.copy(fontSize = 10.sp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Battery(facts.batteryPercent, facts.charging)
                Text("${facts.batteryPercent} %", style = Type.figure.copy(fontSize = 20.sp, lineHeight = 26.sp), maxLines = 1)
            }
        }
        Rule()
        // Free space, read like the battery: a memory card filled with what is free, the figure beside it.
        Column(
            Modifier
                .weight(1f)
                .padding(start = 10.dp, top = 10.dp, bottom = 10.dp, end = 6.dp)
                .semantics(mergeDescendants = true) { contentDescription = "${facts.freeGb} GB libres de ${facts.totalGb}" },
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("LIBRE", style = Type.cota.copy(fontSize = 10.sp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                MemoryCard(if (facts.totalGb > 0) facts.freeGb.toFloat() / facts.totalGb else 0f)
                Text("${facts.freeGb} GB", style = Type.figure.copy(fontSize = 20.sp, lineHeight = 26.sp), maxLines = 1)
            }
        }
    }
}

/**
 * A battery drawn in line: filled to its level, coral when low, summit green with a bolt while charging.
 */
@Composable
private fun Battery(percent: Int, charging: Boolean) {
    val level = percent.coerceIn(0, 100) / 100f
    val fill = when {
        charging -> Ink.ok
        percent <= 15 -> Ink.primary
        else -> Ink.text
    }
    Canvas(Modifier.size(width = 34.dp, height = 18.dp)) {
        val stroke = 1.5.dp.toPx()
        val nub = 3.dp.toPx()
        val body = Size(size.width - nub - stroke, size.height - stroke)
        val corner = androidx.compose.ui.geometry.CornerRadius(4.dp.toPx())
        drawRoundRect(Ink.textMuted, Offset(stroke / 2, stroke / 2), body, corner, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke))
        drawRoundRect(Ink.textMuted, Offset(size.width - nub, size.height * 0.3f), Size(nub, size.height * 0.4f), androidx.compose.ui.geometry.CornerRadius(1.dp.toPx()))
        val inset = stroke + 1.5.dp.toPx()
        val inner = Size((body.width - 2 * inset + stroke) * level, body.height - 2 * inset + stroke)
        drawRoundRect(fill, Offset(inset, inset), inner, androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()))
        if (charging) {
            val w = size.width - nub
            val h = size.height
            val bolt = androidx.compose.ui.graphics.Path().apply {
                moveTo(w * 0.56f, h * 0.12f); lineTo(w * 0.36f, h * 0.56f); lineTo(w * 0.52f, h * 0.56f)
                lineTo(w * 0.44f, h * 0.88f); lineTo(w * 0.66f, h * 0.42f); lineTo(w * 0.5f, h * 0.42f); close()
            }
            drawPath(bolt, Ink.deep)
        }
    }
}

@Composable
private fun Rule() {
    Box(Modifier.width(1.dp).fillMaxHeight().background(Ink.field))
}

/**
 * A memory card, its corner cut, drawn the battery's size: filled in glaciar, the measure colour, as far as the
 * [free] share of the whole; the empty rest is what is used.
 */
@Composable
private fun MemoryCard(free: Float) {
    val f = free.coerceIn(0f, 1f)
    Canvas(Modifier.size(width = 34.dp, height = 18.dp).testTag("free:card")) {
        // Drawn on a 34 x 18 grid, the battery's, scaled to the canvas.
        val u = size.width / 34f
        if (f > 0f) {
            val x = 3f + 28f * f
            val fill = androidx.compose.ui.graphics.Path().apply {
                moveTo(3f * u, 7f * u)
                if (x >= 7f) { lineTo(7f * u, 3f * u); lineTo(x * u, 3f * u) } else lineTo(x * u, (10f - x) * u)
                lineTo(x * u, 15f * u); lineTo(3f * u, 15f * u); close()
            }
            drawPath(fill, Ink.measure)
        }
        val outline = androidx.compose.ui.graphics.Path().apply {
            moveTo(0.75f * u, 6.5f * u); lineTo(6f * u, 0.75f * u); lineTo(31.25f * u, 0.75f * u)
            quadraticTo(33.25f * u, 0.75f * u, 33.25f * u, 2.75f * u); lineTo(33.25f * u, 15.25f * u)
            quadraticTo(33.25f * u, 17.25f * u, 31.25f * u, 17.25f * u); lineTo(2.75f * u, 17.25f * u)
            quadraticTo(0.75f * u, 17.25f * u, 0.75f * u, 15.25f * u); close()
        }
        drawPath(
            outline,
            Ink.textMuted,
            style = androidx.compose.ui.graphics.drawscope.Stroke(1.5.dp.toPx(), join = androidx.compose.ui.graphics.StrokeJoin.Round),
        )
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
    /** The space between the route's rows: more when the camp has room to spare. */
    rowGap: Dp = ROW_GAP,
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
        val dash = with(LocalDensity.current) { floatArrayOf(2.dp.toPx(), 7.dp.toPx()) }
        Column(
            Modifier
                .fillMaxWidth()
                .spot(drag, Spot(Zone.Via, Spot.END))
                .drawBehind {
                    val cell = size.width / 4
                    val rowH = (size.height + rowGap.toPx()) / rows.size
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
            verticalArrangement = Arrangement.spacedBy(rowGap),
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

/** Motif 4, la cordada: the apps you always carry, five abreast. */
@Composable
private fun DockCard(
    apps: List<InstalledApp>,
    home: Home,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    drag: DragBoard,
    onDrop: (Held, Spot) -> Unit,
) {
    val byPackage = apps.associateBy { it.packageName }
    val slots = Dock.pick(byPackage.keys, home.dock, home.dockChosen)
    Column(
        Modifier
            .fillMaxWidth()
            // Room around the home apps, now that the camp has no search bar above them; the apps sit in the
            // middle of their card, with no caption.
            .padding(top = 10.dp, bottom = 18.dp)
            .clip(RoundedCornerShape(28.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.field, RoundedCornerShape(28.dp))
            .padding(horizontal = 8.dp, vertical = 18.dp)
            .semantics { contentDescription = "Dock" },
        verticalArrangement = Arrangement.Center,
    ) {
        // Five equal columns: on a 412dp Pixel five fixed tiles do not fit and labels got clipped.
        Row(Modifier.fillMaxWidth().spot(drag, Spot(Zone.Dock, Spot.END))) {
            slots.forEachIndexed { i, packageName ->
                val app = byPackage.getValue(packageName)
                val deep = app.packageName == "com.termux"
                CarriedTile(
                    app, Zone.Dock, i, drag, if (deep) Ink.ok else Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)],
                    if (deep) Ink.deep else Ink.field, onOpenApp, onAppMenu, onDrop, modifier = Modifier.weight(1f),
                )
            }
            // Room is always kept for five, so a short dock does not stretch its tiles.
            repeat(Home.DOCK_MAX - slots.size) { Spacer(Modifier.weight(1f)) }
        }
    }
}

/** The cordada on its side: the same apps as [DockCard], one above the other down the right edge. */
@Composable
private fun DockRail(
    apps: List<InstalledApp>,
    home: Home,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    drag: DragBoard,
    onDrop: (Held, Spot) -> Unit,
    modifier: Modifier = Modifier,
) {
    val byPackage = apps.associateBy { it.packageName }
    val slots = Dock.pick(byPackage.keys, home.dock, home.dockChosen)
    Column(
        modifier
            .width(76.dp)
            .clip(RoundedCornerShape(28.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.field, RoundedCornerShape(28.dp))
            .padding(vertical = 10.dp)
            .semantics { contentDescription = "Dock" }
            .spot(drag, Spot(Zone.Dock, Spot.END)),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        slots.forEachIndexed { i, packageName ->
            val app = byPackage.getValue(packageName)
            val deep = app.packageName == "com.termux"
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                CarriedTile(
                    app, Zone.Dock, i, drag, if (deep) Ink.ok else Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)],
                    if (deep) Ink.deep else Ink.field, onOpenApp, onAppMenu, onDrop, tile = 52.dp,
                )
            }
        }
        // Room is always kept for five, so a short dock does not bunch its apps.
        repeat(Home.DOCK_MAX - slots.size) { Spacer(Modifier.weight(1f)) }
    }
}
