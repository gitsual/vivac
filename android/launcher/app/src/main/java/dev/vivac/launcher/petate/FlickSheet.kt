package dev.vivac.launcher.petate

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.Type

/** What a flick on an app does: one of its shortcuts, another app, or nothing (the camp swipes as usual). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FlickSheet(
    ask: dev.vivac.launcher.core.FlickAsk,
    apps: List<dev.vivac.launcher.apps.InstalledApp>,
    onChoose: (dev.vivac.launcher.core.Flick?) -> Unit,
    onDismiss: () -> Unit,
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
            Modifier.padding(start = 24.dp, end = 24.dp, bottom = 32.dp, top = 8.dp).heightIn(max = 560.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("AL DESLIZAR SOBRE ELLA", style = Type.cota.copy(fontSize = 10.sp))
            Text(ask.app.label, style = Type.title.copy(fontSize = 28.sp, lineHeight = 30.sp), modifier = Modifier.semantics { heading() })
            Row { Pill("Nada", Ink.raised, Ink.text, Modifier.weight(1f)) { onChoose(null) } }
            if (ask.shortcuts.isNotEmpty()) {
                Text("SUS ATAJOS", style = Type.cota.copy(fontSize = 10.sp))
                ask.shortcuts.forEach { s -> Line(s.label) { onChoose(dev.vivac.launcher.core.Flick.Shortcut(s.id, s.label)) } }
            }
            Text("OTRA APP", style = Type.cota.copy(fontSize = 10.sp))
            apps.forEach { a -> Line(a.label) { onChoose(dev.vivac.launcher.core.Flick.App(a.packageName)) } }
        }
    }
}

@Composable
private fun Line(text: String, onClick: () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(48.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Ink.raised)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.CenterStart,
    ) { Text(text, style = Type.body, maxLines = 1) }
}

@Composable
private fun Pill(text: String, background: Color, color: Color, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .height(52.dp)
            .clip(RoundedCornerShape(26.dp))
            .background(background)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(text, style = Type.body.copy(color = color), maxLines = 1) }
}
