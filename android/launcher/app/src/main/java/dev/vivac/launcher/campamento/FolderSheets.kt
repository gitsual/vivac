package dev.vivac.launcher.campamento

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.AppFace
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.petate.Pack
import dev.vivac.launcher.theme.AppTile
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Sheet(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Ink.surface,
        contentColor = Ink.text,
        scrimColor = Ink.deep.copy(alpha = 0.6f),
        dragHandle = { Box(Modifier.padding(top = 10.dp).size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Ink.borderControl)) },
    ) {
        Column(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 32.dp, top = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }
    }
}

@Composable
private fun Line(text: String, glyph: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.raised)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        LineIcon(glyph, Ink.text, 20.dp)
        Text(text, style = Type.body)
    }
}

/** Which folder an app goes into: one of yours, or a new one. */
@Composable
fun FolderPickSheet(app: InstalledApp, folders: List<Folder>, onPick: (String) -> Unit, onNew: () -> Unit, onDismiss: () -> Unit) {
    Sheet(onDismiss) {
        Text("METER EN UNA CARPETA", style = Type.cota.copy(fontSize = 10.sp))
        Text(app.label, style = Type.title.copy(fontSize = 28.sp, lineHeight = 30.sp), modifier = Modifier.semantics { heading() })
        folders.forEach { f -> Line("${f.name} · ${f.apps.size} apps", Glyph.GRID) { onPick(f.id) } }
        Line("Carpeta nueva", Glyph.PLUS, onNew)
    }
}

/** An open folder: its name (edit it in place), its apps (tap opens; hold takes one out). */
@Composable
fun FolderSheet(
    folder: Folder,
    apps: List<InstalledApp>,
    onOpenApp: (String) -> Unit,
    onTakeOut: (String) -> Unit,
    onRename: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember(folder.id) { mutableStateOf(folder.name) }
    Sheet({ onRename(name); onDismiss() }) {
        Text("CARPETA · ${apps.size} APPS", style = Type.cota.copy(fontSize = 10.sp))
        BasicTextField(
            value = name,
            onValueChange = { name = it },
            singleLine = true,
            textStyle = Type.title.copy(fontSize = 28.sp, lineHeight = 32.sp),
            cursorBrush = SolidColor(Ink.primary),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onRename(name) }),
            modifier = Modifier
                .fillMaxWidth()
                .border(1.dp, Ink.field, RoundedCornerShape(14.dp))
                .padding(horizontal = 12.dp, vertical = 8.dp)
                .semantics { contentDescription = "Nombre de la carpeta" },
        )
        apps.chunked(4).forEach { row ->
            Row(Modifier.fillMaxWidth()) {
                row.forEach { app ->
                    AppTile(
                        label = app.label,
                        background = Ink.raised,
                        border = Ink.field,
                        onClick = { onOpenApp(app.packageName) },
                        onLongClick = { onTakeOut(app.packageName) },
                        modifier = Modifier.weight(1f),
                    ) { AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]) }
                }
                repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
        Text("Mantén pulsada una app para sacarla de la carpeta.", style = Type.small)
    }
}

/** Picks the apps on a ladera: each tap puts an app there, or takes it off again; a search narrows the list. */
@Composable
fun AddToLaderaSheet(page: Int, apps: List<InstalledApp>, here: Set<String>, onToggle: (String) -> Unit, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    Sheet(onDismiss) {
        Text("AÑADIR A LA LADERA $page", style = Type.cota.copy(fontSize = 10.sp))
        Text("Toca las apps que quieres aquí", style = Type.title.copy(fontSize = 24.sp, lineHeight = 28.sp), modifier = Modifier.semantics { heading() })
        Row(
            Modifier
                .fillMaxWidth()
                .border(1.dp, Ink.field, RoundedCornerShape(14.dp))
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            LineIcon(Glyph.SEARCH, Ink.text, 18.dp)
            BasicTextField(
                value = query,
                onValueChange = { query = it },
                singleLine = true,
                textStyle = Type.body.copy(color = Ink.text),
                cursorBrush = SolidColor(Ink.primary),
                modifier = Modifier.weight(1f).semantics { contentDescription = "Buscar app" },
            )
        }
        val shown = apps.filter { query.isBlank() || it.label.contains(query.trim(), ignoreCase = true) }
        LazyColumn(Modifier.heightIn(max = 440.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(shown, key = { it.packageName }) { app ->
                val on = app.packageName in here
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                        .clip(RoundedCornerShape(16.dp))
                        .background(Ink.raised)
                        .border(if (on) 1.5.dp else 0.dp, if (on) Ink.primary else Ink.raised, RoundedCornerShape(16.dp))
                        .clickable(role = Role.Checkbox) { onToggle(app.packageName) }
                        .semantics(mergeDescendants = true) { contentDescription = if (on) "${app.label}, en esta ladera" else app.label }
                        .testTag("adder:${app.packageName}")
                        .padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) { AppFace(app, if (on) Ink.primary else Ink.text) }
                    Text(app.label, style = Type.body, modifier = Modifier.weight(1f), maxLines = 1)
                    if (on) LineIcon(Glyph.CHECK, Ink.primary, 20.dp)
                }
            }
        }
    }
}
