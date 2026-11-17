package dev.vivac.launcher.petate

import androidx.compose.foundation.background
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
    focusSearch: Boolean,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf<Group?>(null) }
    val found = remember(apps, query) { Pack.search(apps, query) }
    val shelves = remember(found, filter) { Pack.grouped(found, filter) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(focusSearch) { if (focusSearch) focus.requestFocus() }

    Column(
        Modifier
            .fillMaxSize()
            .background(Ink.surface)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(Modifier.fillMaxWidth().height(56.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Petate", style = Type.title.copy(fontSize = 28.sp, lineHeight = 36.sp), modifier = Modifier.weight(1f).semantics { heading() })
            Text(Pack.summary(apps), style = Type.mono)
        }
        SearchField(query, { query = it }, focus) { shelves.firstOrNull()?.second?.singleOrNull()?.let { onOpenApp(it.packageName) } }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("Todo", filter == null) { filter = null }
            Group.entries.forEach { g -> Chip(g.title, filter == g) { filter = if (filter == g) null else g } }
        }
        if (shelves.isEmpty()) {
            Text("Nada en el petate con «$query».", style = Type.body.copy(color = Ink.textMuted))
        }
        LazyVerticalGrid(
            columns = GridCells.Fixed(4),
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(bottom = 24.dp),
        ) {
            shelves.forEach { (group, list) ->
                item(key = "h-${group.name}", span = { GridItemSpan(maxLineSpan) }) {
                    Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
                        Text(group.title, style = Type.section, modifier = Modifier.semantics { heading() })
                        Text(group.caption.uppercase(), style = Type.cota)
                    }
                }
                items(list, key = { it.packageName }) { app ->
                    val deep = app.packageName.startsWith("com.termux")
                    AppTile(
                        label = app.label,
                        background = if (deep) Ink.deep else Ink.field,
                        onClick = { onOpenApp(app.packageName) },
                        onLongClick = { onAppMenu(app.packageName) },
                        dot = app.packageName in LocalDots.current,
                    ) {
                        AppFace(app, if (app.packageName == "com.termux") Ink.ok else Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)])
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit, focus: FocusRequester, onGo: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(48.dp).clip(RoundedCornerShape(999.dp)).background(Ink.field).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LineIcon(Glyph.SEARCH, Ink.textMuted, 20.dp)
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) Text("Buscar app", style = Type.body.copy(color = Ink.textMuted))
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
                .background(if (on) Ink.primary else Ink.surface)
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
