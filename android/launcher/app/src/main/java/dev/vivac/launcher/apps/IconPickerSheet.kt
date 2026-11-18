package dev.vivac.launcher.apps

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.core.IconOverride
import dev.vivac.launcher.core.IconPackInfo
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.Type

/**
 * Choosing one app's icon: back to the general style, vivac's glyph, the app's own, or any drawable of an
 * installed pack (searchable by name, since packs hold thousands).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IconPickerSheet(
    app: InstalledApp,
    current: IconOverride?,
    packs: List<IconPackInfo>,
    onPick: (IconOverride?) -> Unit,
    onDismiss: () -> Unit,
) {
    val icons = LocalAppIcons.current
    var pack by rememberSaveable { mutableStateOf((current as? IconOverride.Pack)?.pack ?: packs.firstOrNull()?.packageName) }
    var query by rememberSaveable { mutableStateOf("") }
    val names by produceState(emptyList<String>(), pack, icons) { value = pack?.let { icons?.packIcons(it) }.orEmpty() }
    val shown = remember(names, query) { names.filter { it.contains(query.trim().replace(' ', '_'), ignoreCase = true) }.take(400) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Ink.surface,
        contentColor = Ink.text,
        scrimColor = Ink.deep.copy(alpha = 0.6f),
        dragHandle = { Box(Modifier.padding(top = 10.dp).size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Ink.borderControl)) },
    ) {
        Column(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 24.dp, top = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("CAMBIAR EL ICONO", style = Type.cota.copy(fontSize = 10.sp))
            Text(app.label, style = Type.title.copy(fontSize = 28.sp, lineHeight = 30.sp), modifier = Modifier.semantics { heading() })
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Pill("Como las demás", current == null) { onPick(null) }
                Pill("Glifo de vivac", current == IconOverride.Glyph) { onPick(IconOverride.Glyph) }
                Pill("Icono de la app", current == IconOverride.App) { onPick(IconOverride.App) }
            }
            if (packs.isEmpty()) {
                Text("Con un pack de iconos instalado podrás elegir cualquiera de sus iconos.", style = Type.small)
            } else {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    packs.forEach { p -> Pill(p.label, pack == p.packageName) { pack = p.packageName } }
                }
                BasicTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    textStyle = Type.body,
                    cursorBrush = SolidColor(Ink.primary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(46.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(Ink.deep)
                        .border(1.5.dp, Ink.primary, RoundedCornerShape(14.dp))
                        .padding(horizontal = 12.dp, vertical = 12.dp)
                        .semantics { contentDescription = "Buscar icono en el pack" },
                )
                val chosen = pack
                if (chosen != null) {
                    LazyVerticalGrid(GridCells.Fixed(5), Modifier.heightIn(max = 380.dp), verticalArrangement = Arrangement.spacedBy(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(shown, key = { it }) { name -> PackIcon(chosen, name, current == IconOverride.Pack(chosen, name)) { onPick(IconOverride.Pack(chosen, name)) } }
                    }
                }
            }
        }
    }
}

@Composable
private fun PackIcon(pack: String, name: String, on: Boolean, onClick: () -> Unit) {
    val icons = LocalAppIcons.current
    val image by produceState<ImageBitmap?>(null, pack, name, icons) { value = icons?.packIcon(pack, name) }
    Box(
        Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(14.dp))
            .background(if (on) Ink.primary else Ink.raised)
            .clickable(role = Role.Button, onClickLabel = name, onClick = onClick)
            .semantics { contentDescription = name.replace('_', ' '); selected = on }
            .padding(8.dp),
        contentAlignment = Alignment.Center,
    ) { image?.let { Image(it, null) } }
}

@Composable
private fun Pill(text: String, on: Boolean, onClick: () -> Unit) {
    Text(
        text,
        style = Type.body.copy(color = if (on) Ink.deep else Ink.text),
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(if (on) Ink.primary else Ink.deep)
            .border(1.5.dp, if (on) Ink.primary else Ink.borderControl, RoundedCornerShape(999.dp))
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { selected = on }
            .padding(horizontal = 14.dp, vertical = 10.dp),
    )
}
