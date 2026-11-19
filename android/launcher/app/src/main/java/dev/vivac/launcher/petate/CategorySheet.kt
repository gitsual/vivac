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

/**
 * Changing an app's category: the ones already in the petate as chips, a field for a new one, and Android's own
 * back (a blank choice).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CategorySheet(app: String, current: String?, known: List<String>, onChoose: (String) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Ink.surface,
        contentColor = Ink.text,
        scrimColor = Ink.deep.copy(alpha = 0.6f),
        dragHandle = { Box(Modifier.padding(top = 10.dp).size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Ink.borderControl)) },
    ) {
        Column(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 32.dp, top = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("CAMBIAR LA CATEGORÍA", style = Type.cota.copy(fontSize = 10.sp))
            Text(app, style = Type.title.copy(fontSize = 28.sp, lineHeight = 30.sp), modifier = Modifier.semantics { heading() })
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                known.forEach { c ->
                    val on = c.equals(current, ignoreCase = true)
                    Box(
                        Modifier
                            .height(44.dp)
                            .clip(RoundedCornerShape(22.dp))
                            .background(if (on) Ink.primary else Ink.raised)
                            .clickable(role = Role.Button) { onChoose(c) }
                            .padding(horizontal = 16.dp),
                        contentAlignment = Alignment.Center,
                    ) { Text(c, style = Type.body.copy(color = if (on) Ink.onPrimary else Ink.text)) }
                }
            }
            BasicTextField(
                value = name,
                onValueChange = { name = it },
                singleLine = true,
                textStyle = Type.body,
                cursorBrush = SolidColor(Ink.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { if (name.isNotBlank()) onChoose(name) }),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(Ink.deep)
                    .border(1.5.dp, Ink.primary, RoundedCornerShape(16.dp))
                    .padding(horizontal = 14.dp, vertical = 14.dp)
                    .semantics { contentDescription = "Categoría nueva" },
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Pill("La de Android", Ink.raised, Ink.text, Modifier.weight(1f)) { onChoose("") }
                Pill("Guardar", Ink.primary, Ink.deep, Modifier.weight(1f)) { if (name.isNotBlank()) onChoose(name) }
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
