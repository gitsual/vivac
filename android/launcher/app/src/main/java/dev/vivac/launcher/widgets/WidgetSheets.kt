package dev.vivac.launcher.widgets

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.campamento.WidgetSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import dev.vivac.launcher.petate.Pack
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

/** A placed widget as the Campamento menu lists it. */
data class PlacedWidget(val id: Int, val label: String)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VivacSheet(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Ink.surface,
        contentColor = Ink.text,
        scrimColor = Ink.deep.copy(alpha = 0.6f),
        dragHandle = { Box(Modifier.padding(top = 10.dp).size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Ink.borderControl)) },
    ) {
        Column(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) { content() }
    }
}

/** Long press on the Campamento's background: add a widget, or take one away. */
@Composable
fun CampMenuSheet(
    placed: List<PlacedWidget>,
    dotsAllowed: Boolean,
    onAdd: () -> Unit,
    onRemove: (Int) -> Unit,
    onAllowDots: () -> Unit,
    onDismiss: () -> Unit,
    locked: Boolean = false,
    onToggleLock: () -> Unit = {},
    doubleTapLock: Boolean = false,
    onToggleDoubleTap: () -> Unit = {},
    isHome: Boolean = true,
    onBecomeHome: () -> Unit = {},
    onBackUp: () -> Unit = {},
    onRestore: () -> Unit = {},
    showWallpaper: Boolean = false,
    onToggleWallpaper: () -> Unit = {},
    onChangeWallpaper: () -> Unit = {},
    onSettings: () -> Unit = {},
) {
    VivacSheet(onDismiss) {
        Text("Campamento", style = Type.section, modifier = Modifier.padding(bottom = 8.dp).semantics { heading() })
        if (!isHome) Row52("Hacer de vivac tu app de inicio", Glyph.TENT, Ink.accentText, onBecomeHome)
        Row52("Añadir widget", Glyph.PLUS, Ink.accentText, onAdd)
        Row52("Ajustes de vivac", Glyph.SLIDERS, Ink.text, onSettings)
        Row52(if (locked) "Desbloquear el campamento" else "Bloquear el campamento", Glyph.LOCK, Ink.text, onToggleLock)
        Row52(if (doubleTapLock) "Doble toque: no apagar la pantalla" else "Doble toque: apagar la pantalla", Glyph.DOT, Ink.text, onToggleDoubleTap)
        Row52(if (showWallpaper) "Fondo: noche de vivac" else "Fondo: el del teléfono", Glyph.SQUARE, Ink.text, onToggleWallpaper)
        if (showWallpaper) Row52("Cambiar el fondo de pantalla", Glyph.SQUARE, Ink.text, onChangeWallpaper)
        Row52("Guardar una copia del campamento", Glyph.ARROW, Ink.text, onBackUp)
        Row52("Restaurar una copia", Glyph.PETATE, Ink.text, onRestore)
        placed.forEach { w -> Row52("Quitar «${w.label}»", Glyph.SQUARE, Color(0xFFBD6161)) { onRemove(w.id) } }
        if (!dotsAllowed) {
            Row52("Activar puntos de aviso", Glyph.DOT, Ink.accentText, onAllowDots)
            Text(
                "Android pide darle a vivac acceso a las notificaciones. vivac solo mira de qué app es cada aviso, nunca su texto.",
                style = Type.small,
                modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 2.dp),
            )
        }
    }
}

@Composable
fun WidgetPickerSheet(options: List<WidgetOption>, onPick: (WidgetOption) -> Unit, onDismiss: () -> Unit) {
    VivacSheet(onDismiss) {
        Text("Añadir widget", style = Type.section, modifier = Modifier.semantics { heading() })
        Text("${options.size} widgets de tus apps", style = Type.mono, modifier = Modifier.padding(bottom = 8.dp))
        LazyColumn(Modifier.heightIn(max = 560.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            items(options, key = { it.key }) { option ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 64.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .clickable(role = Role.Button, onClickLabel = "Añadir ${option.label}") { onPick(option) }
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    val app = InstalledApp(option.appLabel, option.appPackage, isSystem = false)
                    Box(Modifier.size(48.dp).clip(RoundedCornerShape(14.dp)).background(Ink.field), contentAlignment = Alignment.Center) {
                        AppFace(app, Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)])
                    }
                    Column(Modifier.weight(1f)) {
                        Text(option.label, style = Type.body)
                        Text(option.appLabel, style = Type.small)
                    }
                    if (option.cells.isNotEmpty()) Text(option.cells, style = Type.mono)
                }
            }
        }
    }
}

@Composable
private fun Row52(label: String, glyph: String, glyphColor: Color, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        LineIcon(glyph, glyphColor, 20.dp)
        Text(label, style = Type.body)
    }
}

/** A round 48dp step button, its glyph named for TalkBack. */
@Composable
internal fun Step(glyph: String, name: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .size(48.dp)
            .clip(CircleShape)
            .border(1.dp, if (enabled) Ink.borderControl else Ink.field, CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = name },
        contentAlignment = Alignment.Center,
    ) { LineIcon(glyph, if (enabled) Ink.text else Ink.borderControl, 22.dp) }
}
