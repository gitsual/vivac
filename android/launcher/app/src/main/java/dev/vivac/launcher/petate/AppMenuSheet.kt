package dev.vivac.launcher.petate

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.vivac.launcher.apps.AppFace
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.widgets.WidgetOption
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppMenuSheet(
    app: InstalledApp,
    entries: List<MenuEntry>,
    canReadShortcuts: Boolean,
    onPick: (MenuEntry) -> Unit,
    onDismiss: () -> Unit,
    widgets: List<WidgetOption> = emptyList(),
    onAddWidget: (WidgetOption) -> Unit = {},
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Ink.surface,
        contentColor = Ink.text,
        scrimColor = Ink.deep.copy(alpha = 0.6f),
        dragHandle = { Box(Modifier.padding(top = 10.dp).size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Ink.borderControl)) },
    ) {
        Column(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(start = 20.dp, end = 20.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.size(72.dp).clip(RoundedCornerShape(24.dp)).background(Ink.field), contentAlignment = Alignment.Center) {
                    AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)])
                }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(app.label, style = Type.title.copy(fontSize = 28.sp, lineHeight = 30.sp, letterSpacing = (-0.03).em), modifier = Modifier.semantics { heading() })
                    Text(app.packageName, style = Type.mono.copy(fontSize = 11.sp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        Pack.groupOf(app).title.uppercase(),
                        style = Type.cota.copy(fontSize = 9.sp, color = Ink.text),
                        modifier = Modifier.border(1.dp, Ink.borderControl, RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
            val shortcuts = entries.filterIsInstance<MenuEntry.Shortcut>()
            val place = entries.filterIsInstance<MenuEntry.Place>()
            if (shortcuts.isNotEmpty() || !canReadShortcuts) {
                Section("ATAJOS") {
                    shortcuts.forEach { entry ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.weight(1f)) { Entry(entry.shortcut.label, Glyph.ARROW, Ink.accentText, Ink.text) { onPick(entry) } }
                            PinButton(entry.shortcut.label) { onPick(MenuEntry.PinShortcut(entry.shortcut)) }
                        }
                    }
                    if (!canReadShortcuts) Text("Los atajos de cada app aparecen cuando vivac es tu app de inicio.", style = Type.small)
                }
            }
            if (widgets.isNotEmpty()) {
                Section("WIDGETS") {
                    widgets.forEach { w ->
                        Entry(if (w.cells.isEmpty()) w.label else "${w.label} · ${w.cells}", Glyph.PLUS, Ink.accentText, Ink.text) { onAddWidget(w) }
                    }
                }
            }
            if (place.isNotEmpty()) {
                Section("SITIO EN EL CAMPAMENTO") {
                    place.forEach { entry ->
                        when (entry) {
                            is MenuEntry.Dock -> Entry(if (entry.inDock) "Quitar del dock" else "Poner en el dock", Glyph.DOCK, Ink.text, Ink.text) { onPick(entry) }
                            is MenuEntry.Pin -> Entry(if (entry.pinned) "Quitar del campamento" else "Fijar en el campamento", Glyph.TENT, Ink.text, Ink.text) { onPick(entry) }
                            is MenuEntry.Ladera -> Entry(if (entry.onLadera) "Quitar de la ladera" else "Poner en una ladera", Glyph.LADERA, Ink.text, Ink.text) { onPick(entry) }
                            is MenuEntry.UnpinShortcut -> Entry("Quitar «${entry.shortcut.label}» de la ladera", Glyph.MINUS, Ink.text, Ink.text) { onPick(entry) }
                            is MenuEntry.Hide -> Entry(if (entry.hidden) "Mostrar en el petate" else "Ocultar del petate", if (entry.hidden) Glyph.EYE else Glyph.EYE_OFF, Ink.text, Ink.text) { onPick(entry) }
                        }
                    }
                }
            }
            // Any app can be renamed; a shortcut's own menu is about the shortcut.
            if (entries.none { it is MenuEntry.UnpinShortcut }) {
                Entry("Meter en una carpeta", Glyph.GRID, Ink.text, Ink.text) { onPick(MenuEntry.ToFolder) }
                Entry("Cambiar el nombre", Glyph.PROMPT, Ink.text, Ink.text) { onPick(MenuEntry.Rename) }
                Entry("Cambiar el icono", Glyph.SQUARE, Ink.text, Ink.text) { onPick(MenuEntry.ChangeIcon) }
                Entry("Cambiar la categoría", Glyph.GRID, Ink.text, Ink.text) { onPick(MenuEntry.Category) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (MenuEntry.Info in entries) Pill("Información de la app", Ink.borderControl, Ink.text, Modifier.weight(1f)) { onPick(MenuEntry.Info) }
                if (MenuEntry.Uninstall in entries) Pill("Desinstalar", Ink.accentText, Ink.accentText, Modifier.weight(1f)) { onPick(MenuEntry.Uninstall) }
            }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.semantics { heading() })
        content()
    }
}

@Composable
private fun Pill(label: String, line: Color, text: Color, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .height(48.dp)
            .clip(RoundedCornerShape(999.dp))
            .border(1.dp, line, RoundedCornerShape(999.dp))
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(label, style = Type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.Medium), color = text, maxLines = 1) }
}

/** Puts a shortcut on a ladera: a square button beside its row. */
@Composable
private fun PinButton(label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(52.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.raised)
            .clickable(role = Role.Button, onClickLabel = "Poner «$label» en una ladera", onClick = onClick)
            .semantics { contentDescription = "Poner «$label» en una ladera" },
        contentAlignment = Alignment.Center,
    ) { LineIcon(Glyph.LADERA, Ink.text, 20.dp) }
}

@Composable
private fun Entry(label: String, glyph: String, glyphColor: Color, textColor: Color, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.raised)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        LineIcon(glyph, glyphColor, 20.dp)
        Text(label, style = Type.body, color = textColor)
    }
}
