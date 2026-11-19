package dev.vivac.launcher.campamento

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
import androidx.compose.runtime.LaunchedEffect
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

/**
 * The pause before an app you chose to open mindfully: its name, today's use when vivac may read it, and the open
 * button that wakes after a few breaths. Dismissing it opens nothing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PauseSheet(ask: dev.vivac.launcher.core.PauseAsk, onOpen: () -> Unit, onAskUsage: () -> Unit, onDismiss: () -> Unit, seconds: Int = 5) {
    var left by remember { mutableStateOf(seconds) }
    LaunchedEffect(ask) {
        while (left > 0) {
            kotlinx.coroutines.delay(1_000)
            left--
        }
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Ink.surface,
        contentColor = Ink.text,
        scrimColor = Ink.deep.copy(alpha = 0.6f),
        dragHandle = { Box(Modifier.padding(top = 10.dp).size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Ink.borderControl)) },
    ) {
        Column(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 32.dp, top = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("UN MOMENTO", style = Type.cota.copy(fontSize = 10.sp))
            Text(ask.app.label, style = Type.title.copy(fontSize = 28.sp, lineHeight = 30.sp), modifier = Modifier.semantics { heading() })
            if (ask.todayMs != null) {
                Text("Hoy: " + dev.vivac.launcher.core.PauseAsk.describe(ask.todayMs), style = Type.body)
            } else {
                Text("Respira. ¿Seguro que quieres abrirla ahora?", style = Type.body)
                Text(
                    "Ver cuánto la usas hoy",
                    style = Type.small.copy(color = Ink.accentText),
                    modifier = Modifier.clickable(role = Role.Button, onClick = onAskUsage).padding(vertical = 8.dp),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Pill("Ahora no", Ink.raised, Ink.text, Modifier.weight(1f), onDismiss)
                if (left > 0) {
                    Pill("Abrir en $left", Ink.field, Ink.textMuted, Modifier.weight(1f)) {}
                } else {
                    Pill("Abrir", Ink.primary, Ink.deep, Modifier.weight(1f), onOpen)
                }
            }
        }
    }
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
