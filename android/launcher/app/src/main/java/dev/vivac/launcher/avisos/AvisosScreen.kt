package dev.vivac.launcher.avisos

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.AppFace
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.core.SystemPage
import dev.vivac.launcher.theme.Brand
import dev.vivac.launcher.theme.Contours
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

/** What the shade can do: each button's action. */
data class AvisosActions(
    val open: (String) -> Unit = {},
    val dismiss: (String) -> Unit = {},
    val dismissAll: () -> Unit = {},
    val reply: (String, String) -> Unit = { _, _ -> },
    val page: (SystemPage) -> Unit = {},
    val torch: () -> Unit = {},
    val system: () -> Unit = {},
    val androidShade: () -> Unit = {},
    val close: () -> Unit = {},
)

/**
 * vivac's own notification shade: a row of quick switches, then every app's notices in a card, newest first. A
 * notice opens with a tap, goes with its cross, and a chat's can be answered right here.
 */
@Composable
fun AvisosScreen(avisos: List<Aviso>, apps: List<InstalledApp>, now: Long, torch: Boolean, act: AvisosActions) {
    val shelf = Avisos.shelf(avisos)
    val byPackage = apps.associateBy { it.packageName }
    Box(Modifier.fillMaxSize().background(Ink.deep)) {
        Contours(Modifier.fillMaxSize(), color = Ink.surface)
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 24.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("VIVAC · AVISOS", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.weight(1f))
                Pill("Cerrar", act.close)
            }
            Text("Avisos", style = Type.title.copy(fontSize = 44.sp, lineHeight = 46.sp, letterSpacing = (-0.04).em, color = Brand.papel50), modifier = Modifier.semantics { heading() })
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Quick(Glyph.WIFI, "Internet", false) { act.page(SystemPage.INTERNET) }
                Quick(Glyph.VOLUME, "Volumen", false) { act.page(SystemPage.VOLUMEN) }
                Quick(Glyph.TORCH, "Linterna", torch, act.torch)
                Quick(Glyph.SLIDERS, "Ajustes", false, act.system)
                Quick(Glyph.BELL, "Android", false, act.androidShade)
            }
            if (shelf.isEmpty()) {
                Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Text("Sin avisos. Todo en calma en el campamento.", style = Type.body.copy(color = Ink.textMuted), textAlign = TextAlign.Center)
                }
            } else {
                LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(shelf, key = { it.packageName }) { group ->
                        GroupCard(group, byPackage[group.packageName], now, act)
                    }
                }
                if (Avisos.anyClearable(avisos)) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Pill("Borrar todo", act.dismissAll) }
                }
            }
        }
    }
}

/** One app's notices: its glyph and name, then each notice. */
@Composable
private fun GroupCard(group: AvisoGroup, app: InstalledApp?, now: Long, act: AvisosActions) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.field, RoundedCornerShape(24.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) { app?.let { AppFace(it, Ink.primary) } }
            Text((app?.label ?: group.packageName).uppercase(), style = Type.cota.copy(fontSize = 11.sp), modifier = Modifier.weight(1f), maxLines = 1)
            Text(Avisos.ago(group.avisos.first().postedAt, now), style = Type.cota.copy(fontSize = 11.sp))
        }
        group.avisos.forEach { aviso -> Notice(aviso, act) }
    }
}

@Composable
private fun Notice(aviso: Aviso, act: AvisosActions) {
    var replying by remember(aviso.key) { mutableStateOf(false) }
    var answer by remember(aviso.key) { mutableStateOf("") }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.raised)
            .clickable(role = Role.Button, onClickLabel = "Abrir") { act.open(aviso.key) }
            .testTag("aviso:${aviso.key}")
            .padding(start = 12.dp, top = 10.dp, bottom = 10.dp, end = 4.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                if (aviso.title.isNotBlank()) Text(aviso.title, style = Type.body.copy(color = Ink.text), maxLines = 1)
                if (aviso.text.isNotBlank()) Text(aviso.text, style = Type.small, maxLines = 4)
            }
            if (aviso.clearable) Round(Glyph.CLOSE, "Descartar") { act.dismiss(aviso.key) }
        }
        if (aviso.canReply) {
            if (!replying) {
                Row(
                    Modifier.clip(RoundedCornerShape(999.dp)).clickable(role = Role.Button) { replying = true }.padding(horizontal = 6.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    LineIcon(Glyph.REPLY, Ink.accentText, 16.dp)
                    Text("Responder", style = Type.small.copy(color = Ink.accentText))
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().padding(end = 8.dp).clip(RoundedCornerShape(14.dp)).border(1.dp, Ink.primary, RoundedCornerShape(14.dp)).padding(start = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val send = { act.reply(aviso.key, answer); answer = ""; replying = false }
                    BasicTextField(
                        value = answer,
                        onValueChange = { answer = it },
                        textStyle = Type.body.copy(color = Ink.text),
                        cursorBrush = SolidColor(Ink.primary),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                        keyboardActions = KeyboardActions(onSend = { send() }),
                        modifier = Modifier.weight(1f).padding(vertical = 10.dp).semantics { contentDescription = "Respuesta" },
                    )
                    Round(Glyph.SEND, "Enviar respuesta", send)
                }
            }
        }
    }
}

/** A quick switch: a round button with its glyph, coral when on, and its name under it. */
@Composable
private fun Quick(glyph: String, label: String, on: Boolean, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(
            Modifier
                .size(56.dp)
                .clip(CircleShape)
                .background(if (on) Ink.primary else Ink.raised)
                .border(1.dp, if (on) Ink.primary else Ink.field, CircleShape)
                .clickable(role = Role.Button, onClick = onClick)
                .semantics { contentDescription = label },
            contentAlignment = Alignment.Center,
        ) { LineIcon(glyph, if (on) Ink.onPrimary else Ink.text, 24.dp) }
        Text(label, style = Type.cota.copy(fontSize = 10.sp))
    }
}

@Composable
private fun Round(glyph: String, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { LineIcon(glyph, Ink.textMuted, 18.dp) }
}

@Composable
private fun Pill(text: String, onClick: () -> Unit) {
    Text(
        text,
        style = Type.body,
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(999.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .border(1.dp, Ink.borderControl, RoundedCornerShape(999.dp))
            .padding(horizontal = 16.dp, vertical = 10.dp),
    )
}
