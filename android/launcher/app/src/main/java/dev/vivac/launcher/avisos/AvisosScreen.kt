package dev.vivac.launcher.avisos

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.AppFace
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.theme.Brand
import dev.vivac.launcher.theme.Contours
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

/** What the shade can do: each button's action. */
data class AvisosActions(
    val open: (String) -> Unit = {},
    val dismiss: (String) -> Unit = {},
    /** One of a notice's own buttons pressed: the notice and the button's place. */
    val act: (String, Int) -> Unit = { _, _ -> },
    val reply: (String, String) -> Unit = { _, _ -> },
    /** A quick switch tapped. */
    val run: (Quick) -> Unit = {},
    /** Into or out of changing the quick switches. */
    val edit: () -> Unit = {},
    val add: (Quick) -> Unit = {},
    val remove: (Quick) -> Unit = {},
    val move: (Quick, Int) -> Unit = { _, _ -> },
    /** Choose apps to have as switches. */
    val pickApps: () -> Unit = {},
    /** The brightness bar moved, 0..1. */
    val brightness: (Float) -> Unit = {},
    /** Clears all of an app's notices. */
    val dismissApp: (String) -> Unit = {},
    /** Android's page for an app's notifications. */
    val noticeSettings: (String) -> Unit = {},
    val close: () -> Unit = {},
)

/** Two rows of switches a page, as Android shows them. */
private const val ROWS = 2
private val TILE_HEIGHT = 100.dp

/**
 * vivac's own notification shade: your quick switches (two rows, or all of them; editable), then every app's
 * notices in a card, newest first. A notice opens with a tap and goes with a swipe or its cross; a chat's can be
 * answered right here.
 */
@Composable
fun AvisosScreen(
    avisos: List<Aviso>,
    apps: List<InstalledApp>,
    now: Long,
    quick: List<Quick>,
    isOn: (Quick) -> Boolean,
    editing: Boolean,
    act: AvisosActions,
    brightness: Float = 0.5f,
) {
    val shelf = Avisos.shelf(avisos)
    val byPackage = apps.associateBy { it.packageName }
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize().background(Ink.deep)) {
        // The rings travel outwards from where the camp's lamp is, top right, as they do on the camp: the shade is
        // pulled down from there.
        val density = androidx.compose.ui.platform.LocalDensity.current
        val top = WindowInsets.safeDrawing.getTop(density)
        val lamp = with(density) { Offset((maxWidth - 46.dp).toPx(), top + 30.dp.toPx()) }
        Contours(Modifier.fillMaxSize(), color = Ink.surface, centre = lamp, innerRadius = 26.dp)
        // Pulling up past the end of the list (or anywhere, when it is short) closes the shade, as Android's does.
        val closing = remember(act) { PullToClose(threshold = 80f * density.density, onClose = act.close) }
        val wide = maxWidth > maxHeight
        val title: @Composable () -> Unit = {
            // On its side height is short: the title a size down.
            Text("Avisos", style = Type.title.copy(fontSize = if (wide) 36.sp else 44.sp, lineHeight = if (wide) 38.sp else 46.sp, letterSpacing = (-0.04).em, color = Brand.papel50), modifier = Modifier.semantics { heading() })
        }
        val notices: androidx.compose.foundation.lazy.LazyListScope.() -> Unit = {
            if (shelf.isEmpty()) {
                item(key = "calm") {
                    Text(
                        "Sin avisos. Todo en calma en el campamento.",
                        style = Type.body.copy(color = Ink.textMuted),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                    )
                }
            }
            items(shelf, key = { it.packageName }) { group ->
                // The whole card swiped to the right takes the app's notices away; each notice inside still
                // goes on its own with a swipe either way.
                if (group.avisos.any { it.clearable }) {
                    Swiped(
                        group.packageName,
                        { act.dismissApp(it) },
                        toLeft = false,
                        modifier = Modifier.testTag("card:${group.packageName}").systemGestureExclusion(),
                    ) { GroupCard(group, byPackage[group.packageName], now, act) }
                } else GroupCard(group, byPackage[group.packageName], now, act)
            }
        }
        val list = Modifier.fillMaxWidth().nestedScroll(closing).testTag("avisos:list")
        val padded = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 24.dp, vertical = 8.dp)
        if (wide) {
            // On its side: the switches and the brightness on the left, the notices beside them with the whole
            // height, so both are in sight at once and no notice hides below the switches.
            Row(padded, horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                Column(
                    Modifier.weight(0.42f).fillMaxHeight().verticalScroll(androidx.compose.foundation.rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    title()
                    QuickSection(quick, byPackage, isOn, editing, act, tileHeight = 86.dp)
                    if (!editing) Brightness(brightness, act.brightness)
                }
                Column(Modifier.weight(0.58f).fillMaxHeight().padding(top = 46.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    LazyColumn(list.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) { notices() }
                }
            }
        } else {
            Column(padded, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                title()
                LazyColumn(list.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    item(key = "quick") { QuickSection(quick, byPackage, isOn, editing, act) }
                    if (!editing) item(key = "brightness") { Brightness(brightness, act.brightness) }
                    notices()
                }
            }
        }
    }
}

/**
 * The quick switches: pages of two rows of four, a swipe for the next whole page. Editing, they are laid out
 * four to a row; a tapped switch is chosen to move or take out, and the ones not in the shade (and apps) wait below.
 */
@Composable
private fun QuickSection(quick: List<Quick>, byPackage: Map<String, InstalledApp>, isOn: (Quick) -> Boolean, editing: Boolean, act: AvisosActions, tileHeight: Dp = TILE_HEIGHT) {
    var chosen by remember { mutableStateOf<Quick?>(null) }
    // A switch whose app is gone is not shown.
    val present = quick.filter { it !is Quick.App || it.packageName in byPackage }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("ATAJOS", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.weight(1f))
            Small(if (editing) "Hecho" else "Editar") { chosen = null; act.edit() }
        }
        if (!editing) {
            // Whole pages of eight, two rows of four filling the width: a swipe brings the next whole page.
            val pages = present.chunked(ROWS * 4)
            val pager = androidx.compose.foundation.pager.rememberPagerState { pages.size }
            androidx.compose.foundation.pager.HorizontalPager(pager, Modifier.fillMaxWidth().testTag("quick:pages")) { p ->
                Column {
                    pages[p].chunked(4).forEach { row ->
                        Row(Modifier.fillMaxWidth()) {
                            row.forEach { q -> QuickTile(q, byPackage, on = isOn(q), chosen = false, Modifier.weight(1f).height(tileHeight)) { act.run(q) } }
                            repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }
            if (pages.size > 1) {
                Row(
                    Modifier.fillMaxWidth().semantics { contentDescription = "Atajos, página ${pager.currentPage + 1} de ${pages.size}" },
                    horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                ) {
                    repeat(pages.size) { i ->
                        Box(
                            Modifier.height(6.dp).width(if (i == pager.currentPage) 18.dp else 6.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(if (i == pager.currentPage) Ink.primary else Ink.borderControl),
                        )
                    }
                }
            }
        } else {
            present.chunked(4).forEach { row ->
                Row(Modifier.fillMaxWidth()) {
                    row.forEach { q ->
                        QuickTile(q, byPackage, on = isOn(q), chosen = chosen == q, Modifier.weight(1f)) {
                            chosen = if (chosen == q) null else q
                        }
                    }
                    repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
        if (editing) {
            val q = chosen
            if (q != null) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    Round(BACK, "Mover antes") { act.move(q, -1) }
                    Pill("Quitar") { act.remove(q); chosen = null }
                    Round(Glyph.ARROW, "Mover después") { act.move(q, +1) }
                }
            } else {
                Text("Toca un atajo para moverlo o quitarlo.", style = Type.small)
            }
            Text("AÑADIR", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.padding(top = 6.dp))
            val extra: List<Quick?> = QuickTiles.available(quick).map { Quick.Of(it) } + null
            extra.chunked(4).forEach { row ->
                Row(Modifier.fillMaxWidth()) {
                    row.forEach { q ->
                        if (q == null) AddTile("Apps", Glyph.PLUS, Modifier.weight(1f), act.pickApps)
                        else AddTile((q as Quick.Of).control.title, glyphOf(q.control), Modifier.weight(1f)) { act.add(q) }
                    }
                    repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

/** The screen's brightness: a sun dim at one end, bright at the other, and a coral bar between. */
@Composable
private fun Brightness(level: Float, onChange: (Float) -> Unit) {
    var shown by remember { mutableStateOf(level) }
    androidx.compose.runtime.LaunchedEffect(level) { shown = level }
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(999.dp))
            .background(Ink.raised)
            .border(1.dp, Ink.field, RoundedCornerShape(999.dp))
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LineIcon(SUN, Ink.textMuted, 16.dp)
        androidx.compose.material3.Slider(
            value = shown,
            onValueChange = { shown = it; onChange(it) },
            modifier = Modifier.weight(1f).semantics { contentDescription = "Brillo" },
            colors = androidx.compose.material3.SliderDefaults.colors(
                thumbColor = Ink.primary,
                activeTrackColor = Ink.primary,
                inactiveTrackColor = Ink.field,
            ),
        )
        LineIcon(SUN, Ink.text, 22.dp)
    }
}

private const val SUN = "M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8z M12 2v2 M12 20v2 M4 12H2 M22 12h-2 M5 5l1.5 1.5 M17.5 17.5L19 19 M5 19l1.5-1.5 M17.5 6.5L19 5"

/** A quick switch: a round button, coral when on (or chosen to edit), its name under it. */
@Composable
private fun QuickTile(q: Quick, byPackage: Map<String, InstalledApp>, on: Boolean, chosen: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val label = when (q) {
        is Quick.Of -> q.control.title
        is Quick.App -> byPackage[q.packageName]?.label ?: q.packageName
    }
    Column(
        modifier
            .clip(RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = if (on) "$label, activado" else label }
            .testTag("quick:$label")
            .padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier
                .size(56.dp)
                .clip(CircleShape)
                .background(if (on) Ink.primary else Ink.raised)
                .border(if (chosen) 2.dp else 1.dp, if (on || chosen) Ink.primary else Ink.field, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            when (q) {
                is Quick.Of -> LineIcon(glyphOf(q.control), if (on) Ink.onPrimary else Ink.text, 24.dp)
                is Quick.App -> byPackage[q.packageName]?.let { Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) { AppFace(it, Ink.text) } }
            }
        }
        Text(label, style = Type.cota.copy(fontSize = 10.sp), maxLines = 2, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

/** A switch that can be added: dashed-looking, with a plus. */
@Composable
private fun AddTile(label: String, glyph: String, modifier: Modifier, onClick: () -> Unit) {
    Column(
        modifier
            .clip(RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClickLabel = "Añadir", onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = "Añadir $label" }
            .padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(56.dp).clip(CircleShape).border(1.dp, Ink.borderControl, CircleShape), contentAlignment = Alignment.Center) {
            LineIcon(glyph, Ink.textMuted, 22.dp)
        }
        Text(label, style = Type.cota.copy(fontSize = 10.sp), maxLines = 2, textAlign = TextAlign.Center)
    }
}

@Composable
private fun Small(text: String, onClick: () -> Unit) {
    Text(
        text,
        style = Type.small.copy(color = Ink.accentText),
        modifier = Modifier.clip(RoundedCornerShape(999.dp)).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 10.dp, vertical = 8.dp),
    )
}

private const val BACK = "M19 12H5M11 6l-6 6 6 6"

/** Each control's line glyph, drawn on vivac's 24-unit grid. */
internal fun glyphOf(c: Control): String = when (c) {
    Control.WIFI -> Glyph.WIFI
    Control.BLUETOOTH -> "M7 7l10 10-5 5V2l5 5L7 17"
    Control.DATOS -> "M4 20v-3 M9 20v-7 M14 20v-11 M19 20V4"
    Control.AVION -> "M12 3c1 0 1.5 1 1.5 2v5l7 4v2l-7-2v4l2 1.5V21l-3.5-1-3.5 1v-1.5l2-1.5v-4l-7 2v-2l7-4V5c0-1 .5-2 1.5-2z"
    Control.NO_MOLESTAR -> "M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"
    Control.LINTERNA -> Glyph.TORCH
    Control.ROTACION -> "M4 12a8 8 0 0 1 14-5.3 M18 3v4h-4 M20 12a8 8 0 0 1-14 5.3 M6 21v-4h4"
    Control.ALARMA -> "M12 9v4l2.5 1.5 M12 21a8 8 0 1 0 0-16a8 8 0 1 0 0 16z M4 5l3-2.5 M20 5l-3-2.5"
    Control.GRABAR -> "M12 4a8 8 0 1 0 0 16a8 8 0 1 0 0-16z M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6z"
    Control.AHORRO -> "M3 8h15v8H3z M21 11v2 M6 11h4"
    Control.MICRO -> "M9 5a3 3 0 0 1 6 0v6a3 3 0 0 1-6 0z M5 11a7 7 0 0 0 14 0 M12 18v3"
    Control.CAMARA -> "M3 8h4l2-3h6l2 3h4v11H3z M12 10a3.5 3.5 0 1 0 0 7a3.5 3.5 0 1 0 0-7z"
    Control.UBICACION -> "M12 21s-6-6-6-11a6 6 0 0 1 12 0c0 5-6 11-6 11z M12 8a2 2 0 1 0 0 4a2 2 0 1 0 0-4z"
    Control.ENVIAR -> "M3 7V5h18v14h-7 M3 11a8 8 0 0 1 8 8 M3 15a4 4 0 0 1 4 4 M3 19h.01"
    Control.COMPARTIR -> "M12 12h.01 M8.5 15.5a5 5 0 0 1 0-7 M15.5 8.5a5 5 0 0 1 0 7 M5.5 18.5a9 9 0 0 1 0-13 M18.5 5.5a9 9 0 0 1 0 13"
    Control.VOLUMEN -> Glyph.VOLUME
    Control.AJUSTES -> Glyph.SLIDERS
    Control.ANDROID -> Glyph.BELL
    Control.NFC -> "M6 8a6 6 0 0 0 0 8 M9.5 5.5a10 10 0 0 1 0 13 M15 7v10 M15 7l4 10 M19 7v10"
    Control.TEMA -> "M12 3a9 9 0 1 0 0 18z M12 3a9 9 0 0 1 0 18"
    Control.LUZ -> "M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8z M12 2v2 M12 20v2 M4 12H2 M22 12h-2 M5 5l1.5 1.5 M17.5 17.5L19 19 M5 19l1.5-1.5 M17.5 6.5L19 5"
}

/** One app's notices: its glyph and name, then each notice. */
@Composable
private fun GroupCard(group: AvisoGroup, app: InstalledApp?, now: Long, act: AvisosActions) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.field, RoundedCornerShape(24.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) { app?.let { AppFace(it, Ink.primary) } }
            Text((app?.label ?: group.avisos.first().appLabel.ifBlank { "Sistema" }).uppercase(), style = Type.cota.copy(fontSize = 11.sp), modifier = Modifier.weight(1f), maxLines = 1)
            Text(Avisos.ago(group.avisos.first().postedAt, now), style = Type.cota.copy(fontSize = 11.sp))
            val name = app?.label ?: group.avisos.first().appLabel.ifBlank { "Sistema" }
            Round(Glyph.SLIDERS, "Ajustes de los avisos de $name") { act.noticeSettings(group.packageName) }
            if (group.avisos.count { it.clearable } > 1) Round(Glyph.CLOSE, "Descartar los de $name") { act.dismissApp(group.packageName) }
        }
        // Keyed by the notice, so a swipe's state stays with its own notice when the one above it goes.
        group.avisos.forEach { aviso ->
            androidx.compose.runtime.key(aviso.key) {
                if (aviso.clearable) Swiped(aviso.key, act.dismiss) { Notice(aviso, act) } else Notice(aviso, act)
            }
        }
    }
}

@Composable
private fun Notice(aviso: Aviso, act: AvisosActions) {
    var replying by remember(aviso.key) { mutableStateOf(false) }
    var answer by remember(aviso.key) { mutableStateOf("") }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.raised)
            .clickable(role = Role.Button, onClickLabel = "Abrir") { act.open(aviso.key) }
            .testTag("aviso:${aviso.key}")
            .padding(start = 12.dp, top = 10.dp, bottom = 10.dp, end = 4.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            // Who it is from, when the app says: a face reads faster than a name.
            aviso.avatar?.let {
                androidx.compose.foundation.Image(
                    it, null,
                    Modifier.padding(top = 2.dp).size(36.dp).clip(CircleShape).testTag("avatar:${aviso.key}"),
                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (aviso.title.isNotBlank()) Text(aviso.title, style = Type.body.copy(color = Ink.text), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (aviso.detail.isNotBlank()) Text(aviso.detail, style = Type.small, maxLines = 1)
                }
                if (aviso.text.isNotBlank()) Text(aviso.text, style = Type.small, maxLines = 10, overflow = TextOverflow.Ellipsis)
            }
            if (aviso.clearable) Round(Glyph.CLOSE, "Descartar") { act.dismiss(aviso.key) }
        }
        aviso.picture?.let {
            androidx.compose.foundation.Image(
                it, "Imagen del aviso",
                Modifier.fillMaxWidth().padding(end = 8.dp).heightIn(max = 200.dp).clip(RoundedCornerShape(12.dp)),
                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
            )
        }
        if (aviso.canReply || aviso.actions.isNotEmpty()) {
            if (!replying) {
                // The written reply first, then the app's own buttons, as it names them.
                Row(Modifier.horizontalScroll(androidx.compose.foundation.rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (aviso.canReply) Row(
                        Modifier.heightIn(min = 36.dp).clip(RoundedCornerShape(999.dp)).clickable(role = Role.Button) { replying = true }.padding(horizontal = 8.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        LineIcon(Glyph.REPLY, Ink.accentText, 16.dp)
                        Text("Responder", style = Type.small.copy(color = Ink.accentText))
                    }
                    aviso.actions.forEachIndexed { i, name ->
                        Box(
                            Modifier.heightIn(min = 36.dp).clip(RoundedCornerShape(999.dp)).clickable(role = Role.Button) { act.act(aviso.key, i) }.padding(horizontal = 8.dp, vertical = 4.dp),
                            contentAlignment = Alignment.Center,
                        ) { Text(name, style = Type.small.copy(color = Ink.accentText), maxLines = 1) }
                    }
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().padding(end = 8.dp).clip(RoundedCornerShape(14.dp)).border(1.dp, Ink.primary, RoundedCornerShape(14.dp)).padding(start = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val send = { act.reply(aviso.key, answer); answer = ""; replying = false }
                    BasicTextField(
                        value = answer,
                        onValueChange = { answer = it },
                        textStyle = Type.body.copy(color = Ink.text),
                        cursorBrush = SolidColor(Ink.primary),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                        keyboardActions = KeyboardActions(onSend = { send() }),
                        modifier = Modifier.weight(1f).padding(vertical = 10.dp).semantics { contentDescription = "Respuesta" },
                    )
                    Round(Glyph.SEND, "Enviar respuesta", send)
                }
            }
        }
    }
}

/** A notice that goes when swiped off either side. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun Swiped(
    key: String,
    onDismiss: (String) -> Unit,
    toLeft: Boolean = true,
    modifier: Modifier = Modifier.testTag("swipe:$key"),
    content: @Composable () -> Unit,
) {
    // The box asks more than once as the swipe settles; the notice is dismissed only the first time.
    var gone by remember { mutableStateOf(false) }
    val state = androidx.compose.material3.rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            val away = value != androidx.compose.material3.SwipeToDismissBoxValue.Settled
            if (away && !gone) { gone = true; onDismiss(key) }
            away
        },
    )
    androidx.compose.material3.SwipeToDismissBox(state, backgroundContent = {}, modifier = modifier, enableDismissFromEndToStart = toLeft) { content() }
}

@Composable
private fun Round(glyph: String, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { LineIcon(glyph, Ink.textMuted, 18.dp) }
}

@Composable
private fun Pill(text: String, onClick: () -> Unit) {
    Text(
        text,
        style = Type.body,
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(999.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .border(1.dp, Ink.borderControl, RoundedCornerShape(999.dp))
            .padding(horizontal = 16.dp, vertical = 10.dp),
    )
}

/**
 * Closes the shade when the finger keeps pulling after the list can go no further: up past its end, or down past
 * its top.
 */
private class PullToClose(private val threshold: Float, private val onClose: () -> Unit) :
    androidx.compose.ui.input.nestedscroll.NestedScrollConnection {
    private var pull = 0f

    override fun onPostScroll(
        consumed: androidx.compose.ui.geometry.Offset,
        available: androidx.compose.ui.geometry.Offset,
        source: androidx.compose.ui.input.nestedscroll.NestedScrollSource,
    ): androidx.compose.ui.geometry.Offset {
        if (source == androidx.compose.ui.input.nestedscroll.NestedScrollSource.UserInput) pull += available.y
        return androidx.compose.ui.geometry.Offset.Zero
    }

    override suspend fun onPreFling(available: androidx.compose.ui.unit.Velocity): androidx.compose.ui.unit.Velocity {
        val close = kotlin.math.abs(pull) > threshold
        pull = 0f
        if (close) onClose()
        return androidx.compose.ui.unit.Velocity.Zero
    }
}
