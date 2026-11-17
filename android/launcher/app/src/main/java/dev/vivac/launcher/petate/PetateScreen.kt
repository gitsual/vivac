package dev.vivac.launcher.petate

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.em
import dev.vivac.launcher.theme.Brand
import dev.vivac.launcher.theme.Contours
import kotlinx.coroutines.launch
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.AppFace
import dev.vivac.launcher.apps.LocalDots
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.theme.AppTile
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Monogram
import dev.vivac.launcher.theme.Type

@Composable
fun PetateScreen(
    apps: List<InstalledApp>,
    hidden: Set<String>,
    focusSearch: Boolean,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    recent: List<InstalledApp> = emptyList(),
) {
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf<Group?>(null) }
    var showHidden by rememberSaveable { mutableStateOf(false) }
    if (hidden.isEmpty()) showHidden = false
    val found = remember(apps, hidden, showHidden, query) { Pack.search(Pack.visible(apps, hidden, showHidden), query) }
    val shelves = remember(found, filter) { Pack.grouped(found, filter) }
    val jumps = remember(shelves) { Pack.jumps(shelves) }
    val grid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    var letter by remember { mutableStateOf<Char?>(null) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(focusSearch) { if (focusSearch) focus.requestFocus() }

    Box(Modifier.fillMaxSize().background(Ink.deep)) {
        Contours(Modifier.fillMaxSize(), color = Ink.surface)
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(start = 24.dp, top = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.padding(end = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(Modifier.fillMaxWidth()) {
                    Text("PETATE · MATERIAL", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.weight(1f))
                    Text(Pack.summary(apps).uppercase(), style = Type.cota.copy(fontSize = 10.sp))
                }
                Text("Petate", style = Type.title.copy(fontSize = 44.sp, lineHeight = 46.sp, letterSpacing = (-0.04).em, color = Brand.papel50), modifier = Modifier.semantics { heading() })
                SearchField(query, { query = it }, focus) { shelves.firstOrNull()?.second?.singleOrNull()?.let { onOpenApp(it.packageName) } }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("Todo", filter == null && !showHidden) { filter = null; showHidden = false }
                    Group.entries.forEach { g -> Chip(g.title, filter == g && !showHidden) { filter = if (filter == g) null else g; showHidden = false } }
                    if (hidden.isNotEmpty()) Chip("Ocultas · ${hidden.size}", showHidden) { showHidden = !showHidden; filter = null }
                }
                if (recent.isNotEmpty() && query.isBlank() && !showHidden) LastPitch(recent, onOpenApp, onAppMenu)
                if (shelves.isEmpty()) {
                    Text("Nada en el petate con «$query».", style = Type.body.copy(color = Ink.textMuted))
                }
            }
            Row(Modifier.weight(1f)) {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(4),
                    state = grid,
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                    contentPadding = PaddingValues(bottom = 24.dp),
                ) {
                    shelves.forEach { (group, list) ->
                        item(key = "h-${group.name}", span = { GridItemSpan(maxLineSpan) }) { ShelfHeader(group, list.size) }
                        items(list, key = { it.packageName }) { app ->
                            val deep = app.packageName.startsWith("com.termux")
                            AppTile(
                                label = app.label,
                                background = if (deep) Ink.deep else Ink.surface,
                                border = Ink.field,
                                onClick = { onOpenApp(app.packageName) },
                                onLongClick = { onAppMenu(app.packageName) },
                                dot = app.packageName in LocalDots.current,
                            ) {
                                AppFace(app, if (app.packageName == "com.termux") Ink.ok else Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)])
                            }
                        }
                    }
                }
                Altimeter(jumps.keys, letter) { ch ->
                    letter = ch
                    jumps[ch]?.let { scope.launch { grid.scrollToItem(it) } }
                }
            }
        }
    }
}

/** A shelf: its name, what it holds, how many, over a hairline. */
@Composable
private fun ShelfHeader(group: Group, count: Int) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = 8.dp, end = 4.dp)
            .drawBehind { drawLine(Ink.field, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) }
            .padding(bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        Text(group.title, style = Type.section, modifier = Modifier.semantics { heading() })
        Text(group.caption, style = Type.small, modifier = Modifier.weight(1f))
        Text("$count", style = Type.cota.copy(fontSize = 10.sp))
    }
}

/** "Último largo": the apps you opened last through vivac, newest first. */
@Composable
private fun LastPitch(recent: List<InstalledApp>, onOpenApp: (String) -> Unit, onAppMenu: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("ÚLTIMO LARGO", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.semantics { heading() })
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            recent.forEach { app ->
                AppTile(
                    label = app.label,
                    background = Ink.surface,
                    border = Ink.field,
                    tile = 48.dp,
                    onClick = { onOpenApp(app.packageName) },
                    onLongClick = { onAppMenu(app.packageName) },
                    modifier = Modifier.width(60.dp),
                ) { AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]) }
            }
        }
    }
}

private val ALTIMETER = "#ABCDEFGHIJKLMNOPQRSTUVWXYZ".toList()

/**
 * The altimeter: every letter as a mark on the right edge. Letters with apps jump there (tap or slide along it);
 * the rest are only marks, so TalkBack lists just the ones that go somewhere.
 */
@Composable
private fun Altimeter(present: Set<Char>, current: Char?, onJump: (Char) -> Unit) {
    var height by remember { mutableStateOf(1) }
    Column(
        Modifier
            .width(32.dp)
            .fillMaxHeight()
            .padding(bottom = 16.dp)
            .onSizeChanged { height = it.height }
            .semantics { contentDescription = "Altímetro: desliza para saltar de letra" }
            .pointerInput(present) {
                detectVerticalDragGestures { change, _ ->
                    val i = (change.position.y / height * ALTIMETER.size).toInt().coerceIn(0, ALTIMETER.lastIndex)
                    ALTIMETER[i].takeIf { it in present }?.let(onJump)
                }
            },
        verticalArrangement = Arrangement.SpaceBetween,
        horizontalAlignment = Alignment.End,
    ) {
        ALTIMETER.forEach { ch ->
            val on = ch == current
            val has = ch in present
            Row(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .then(if (has) Modifier.clickable(role = Role.Button, onClickLabel = "Saltar a la $ch") { onJump(ch) }.semantics { contentDescription = "Saltar a la $ch" } else Modifier.clearAndSetSemantics { }),
                horizontalArrangement = Arrangement.spacedBy(3.dp, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "$ch",
                    style = Type.mono.copy(fontSize = 10.sp, lineHeight = 10.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal),
                    color = when { on -> Ink.accentText; has -> Ink.textMuted; else -> Ink.field },
                )
                Box(Modifier.padding(end = 6.dp).width(if (on) 10.dp else 4.dp).height(1.dp).background(if (on) Ink.accentText else Ink.field))
            }
        }
    }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit, focus: FocusRequester, onGo: () -> Unit) {
    Text("BUSCAR · NOMBRE O INICIALES", style = Type.cota.copy(fontSize = 10.sp))
    Row(
        Modifier
            .fillMaxWidth()
            .height(50.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.surface)
            .border(1.5.dp, Ink.primary, RoundedCornerShape(16.dp))
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LineIcon(Glyph.SEARCH, Ink.text, 20.dp)
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) Text("Organic Maps → om", style = Type.body.copy(color = Ink.textMuted))
            BasicTextField(
                value = query,
                onValueChange = onChange,
                singleLine = true,
                textStyle = Type.body,
                cursorBrush = SolidColor(Ink.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { onGo() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus).semantics { contentDescription = "Buscar en el petate" },
            )
        }
    }
}

/** Filter chip: 36dp pill inside a 44dp touch target; selected = coral fill, never colour alone (weight changes too). */
@Composable
private fun Chip(text: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .heightIn(min = 44.dp)
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics { selected = on },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .height(36.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(if (on) Ink.primary else Ink.deep)
                .border(1.5.dp, if (on) Ink.primary else Ink.borderControl, RoundedCornerShape(999.dp))
                .padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text,
                style = Type.body.copy(fontSize = 14.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Medium),
                color = if (on) Ink.onPrimary else Ink.text,
            )
        }
    }
}
