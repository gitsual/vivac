package dev.vivac.launcher.campamento

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitLongPressOrCancellation
import androidx.compose.foundation.gestures.drag
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.core.Zone

/** Something being carried, from [from]; [takes] says which zones it can land in. */
sealed interface Cargo {
    val from: Zone
    fun takes(zone: Zone): Boolean
}

/** An app being carried: what it is, where it came from, and the tone its tile is drawn in. Never onto the camp's widgets. */
data class Held(val app: InstalledApp, override val from: Zone, val tone: Color) : Cargo {
    override fun takes(zone: Zone) = zone != Zone.Ladera(0) && zone != Zone.Petate
}

/** A shortcut or a folder being carried: it lands only on a ladera. */
data class HeldItem(val item: Item, override val from: Zone, val label: String) : Cargo {
    override fun takes(zone: Zone) = zone is Zone.Ladera && zone.page >= 1
}

/** A widget being carried: it lands only among the things on a page. */
data class HeldWidget(val id: Int, override val from: Zone, val label: String) : Cargo {
    override fun takes(zone: Zone) = zone is Zone.Ladera
}

/** A place a carried app can land: a tile's spot in a zone, or the end of a zone ([index] = [END]). */
data class Spot(val zone: Zone, val index: Int) {
    companion object { const val END = Int.MAX_VALUE }
}

/**
 * One drag at a time across the home screen: what is held, where the finger is (in root coordinates),
 * and every spot that can take it, as the screen last laid them out.
 */
class DragBoard {
    var held by mutableStateOf<Cargo?>(null); private set
    var finger by mutableStateOf(Offset.Zero); private set
    private val spots = mutableMapOf<Spot, Rect>()
    /** The visible area: spots outside it (a ladera off screen) take nothing. */
    var screen = Rect.Zero
    /** A locked camp: nothing can be picked up. */
    var locked = false

    fun place(spot: Spot, bounds: Rect) { spots[spot] = bounds }

    /** Where each app's tile sits on the camp, by zone: what Android's swipe home animates a closing app into. */
    private val tiles = mutableMapOf<Pair<String, Zone>, Rect>()

    fun placeTile(packageName: String, zone: Zone, bounds: Rect) { tiles[packageName to zone] = bounds }

    /** The app's tile on screen: in the dock first (always visible), else on the route, else none. */
    fun tileOf(packageName: String): Rect? = listOf(Zone.Dock, Zone.Via).firstNotNullOfOrNull { zone ->
        tiles[packageName to zone]?.takeIf { screen == Rect.Zero || it.overlaps(screen) }
    }
    fun forget(spot: Spot) { spots.remove(spot) }

    fun pick(held: Cargo, at: Offset) {
        if (locked) return
        this.held = held; finger = at
    }
    fun move(by: Offset) { finger += by }
    fun cancel() { held = null }

    /** Where the carried thing would land now: the tile under the finger, else the zone it is over. */
    val target: Spot? get() = held?.let { spotAt(finger) }

    fun spotAt(at: Offset): Spot? {
        val cargo = held
        val visible = spots.filter { (spot, bounds) ->
            (screen == Rect.Zero || bounds.overlaps(screen)) && (cargo == null || cargo.takes(spot.zone))
        }
        visible.entries.filter { it.key.index != Spot.END }.firstOrNull { it.value.contains(at) }?.let { return it.key }
        return visible.entries.firstOrNull { it.key.index == Spot.END && it.value.contains(at) }?.key
    }

    /** Lets go: the drop it makes, or null when the finger is over nothing that takes apps. */
    fun release(): Pair<Cargo, Spot>? {
        val h = held ?: return null
        val spot = spotAt(finger)
        held = null
        return spot?.let { h to it }
    }
}

/** Registers [spot] with the board while this element is on screen. */
@Composable
fun Modifier.spot(board: DragBoard, spot: Spot): Modifier {
    DisposableEffect(board, spot) { onDispose { board.forget(spot) } }
    return onGloballyPositioned { board.place(spot, it.boundsInRoot()) }
}

/**
 * The gestures of a tile that can be carried: tap opens it; holding opens its menu; holding and moving lifts it
 * and carries it to wherever it is let go, then [onLand] runs whether it landed or not. TalkBack keeps the plain open and options actions.
 */
@Composable
fun Modifier.carriable(
    board: DragBoard,
    held: Held,
    label: String,
    onOpen: () -> Unit,
    onMenu: () -> Unit,
    onDrop: (Held, Spot) -> Unit,
    onLand: () -> Unit = {},
): Modifier = carrying(board, held, label, onOpen, onMenu, { c, s -> onDrop(c as Held, s) }, onLand)

/** [carriable] for anything that can be carried: an app, a shortcut, a folder. */
@Composable
fun Modifier.carrying(
    board: DragBoard,
    held: Cargo,
    label: String,
    onOpen: () -> Unit,
    onMenu: () -> Unit,
    onDrop: (Cargo, Spot) -> Unit,
    onLand: () -> Unit = {},
): Modifier {
    val haptics = LocalHapticFeedback.current
    var origin by remember { mutableStateOf(Offset.Zero) }
    return this
        .onGloballyPositioned { origin = it.positionInRoot() }
        .semantics {
            role = Role.Button
            onClick("Abrir $label") { onOpen(); true }
            onLongClick("Opciones de $label") { onMenu(); true }
        }
        .pointerInput(held) {
            awaitEachGesture {
                // Taken here, so the camp's own long press (its menu) does not also fire.
                val down = awaitFirstDown().also { it.consume() }
                val press = awaitLongPressOrCancellation(down.id)
                if (press == null) {
                    // Let go before the long-press time without moving away: a tap.
                    val up = currentEvent.changes.firstOrNull { it.id == down.id }
                    if (up != null && !up.pressed && !up.isConsumed) onOpen()
                    return@awaitEachGesture
                }
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                var moved = 0f
                board.pick(held, origin + press.position)
                drag(press.id) { change ->
                    val by = change.positionChange()
                    moved += by.getDistance()
                    board.move(by)
                    change.consume()
                }
                if (moved < viewConfiguration.touchSlop) {
                    board.cancel()
                    onMenu()
                } else if (board.held != null) {
                    board.release()?.let { (h, s) -> onDrop(h, s) }
                    onLand()
                }
            }
        }
}
