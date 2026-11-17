package dev.vivac.launcher.petate

import androidx.compose.foundation.background
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
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

/** Retirada (alert) family: the red is shape only; its text uses the light tint (red text fails contrast). */
private val retiradaShape = Color(0xFFBD6161)
private val retiradaText = Color(0xFFF3CACA)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppMenuSheet(
    app: InstalledApp,
    entries: List<MenuEntry>,
    canReadShortcuts: Boolean,
    onPick: (MenuEntry) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Ink.raised,
        contentColor = Ink.text,
        scrimColor = Ink.deep.copy(alpha = 0.6f),
        dragHandle = { Box(Modifier.padding(top = 10.dp).size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Ink.borderControl)) },
    ) {
        Column(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(start = 20.dp, end = 20.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(Modifier.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.size(56.dp).clip(RoundedCornerShape(18.dp)).background(Ink.field), contentAlignment = Alignment.Center) {
                    AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)])
                }
                Column {
                    Text(app.label, style = Type.section, modifier = Modifier.semantics { heading() })
                    Text(app.packageName, style = Type.mono)
                }
            }
            entries.forEach { entry ->
                when (entry) {
                    is MenuEntry.Shortcut -> Entry(entry.shortcut.label, Glyph.ARROW, Ink.accentText, Ink.text) { onPick(entry) }
                    is MenuEntry.Dock -> Entry(if (entry.inDock) "Quitar del dock" else "Poner en el dock", Glyph.DOCK, Ink.text, Ink.text) { onPick(entry) }
                    is MenuEntry.Pin -> Entry(if (entry.pinned) "Quitar del campamento" else "Fijar en el campamento", Glyph.TENT, Ink.text, Ink.text) { onPick(entry) }
                    MenuEntry.Info -> Entry("Información de la app", Glyph.INFO, Ink.text, Ink.text) { onPick(entry) }
                    MenuEntry.Uninstall -> Entry("Desinstalar", Glyph.SQUARE, retiradaShape, retiradaText) { onPick(entry) }
                }
            }
            if (!canReadShortcuts) {
                Text(
                    "Los atajos de cada app aparecen cuando vivac es tu app de inicio.",
                    style = Type.small,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun Entry(label: String, glyph: String, glyphColor: Color, textColor: Color, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        LineIcon(glyph, glyphColor, 20.dp)
        Text(label, style = Type.body, color = textColor)
    }
}
