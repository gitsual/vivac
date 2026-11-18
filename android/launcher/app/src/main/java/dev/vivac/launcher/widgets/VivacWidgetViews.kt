package dev.vivac.launcher.widgets

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.AppFace
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.avisos.Aviso
import dev.vivac.launcher.avisos.Avisos
import dev.vivac.launcher.campamento.ShortcutGlyph
import dev.vivac.launcher.petate.AppShortcut
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

/** vivac's card for its own widgets: its surface, a hairline and its corners. */
@Composable
private fun VivacCard(content: @Composable () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(24.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.field, RoundedCornerShape(24.dp)),
    ) { content() }
}

/**
 * A chat app's latest conversations, from its notifications: who, what they said, and when. A tap opens that
 * conversation; the header opens the app. As many fit as the rows allow.
 */
@Composable
fun ChatsWidget(app: InstalledApp?, packageName: String, avisos: List<Aviso>, now: Long, onOpen: (String) -> Unit, onOpenApp: () -> Unit) {
    val chats = avisos.filter { it.packageName == packageName && !it.summary && (it.title.isNotBlank() || it.text.isNotBlank()) }
        .sortedByDescending { it.postedAt }
    VivacCard {
        BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp)) {
            val fit = ((maxHeight.value - HEADER) / ROW).toInt().coerceAtLeast(0)
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(
                    Modifier.fillMaxWidth().height(28.dp).clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClickLabel = "Abrir", onClick = onOpenApp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) { app?.let { AppFace(it, Ink.primary) } }
                    Text((app?.label ?: packageName).uppercase(), style = Type.cota.copy(fontSize = 11.sp), modifier = Modifier.weight(1f), maxLines = 1)
                    Text(if (chats.isEmpty()) "AL DÍA" else "${chats.size} NUEVOS", style = Type.cota.copy(fontSize = 10.sp, color = Ink.accentText))
                }
                if (chats.isEmpty()) {
                    Text("Sin mensajes nuevos.", style = Type.small, modifier = Modifier.padding(top = 6.dp))
                }
                chats.take(fit).forEach { chat ->
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .height(ROW.dp - 6.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(Ink.raised)
                            .clickable(role = Role.Button, onClickLabel = "Abrir") { onOpen(chat.key) }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(chat.title, style = Type.body.copy(fontSize = 15.sp, lineHeight = 18.sp), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Text(Avisos.ago(chat.postedAt, now), style = Type.cota.copy(fontSize = 10.sp))
                        }
                        Text(chat.text, style = Type.small.copy(lineHeight = 16.sp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

/** An app's shortcuts as vivac buttons: the app itself first, then each shortcut with a glyph for what it does. */
@Composable
fun AtajosWidget(app: InstalledApp?, shortcuts: List<AppShortcut>, onShortcut: (String) -> Unit, onOpenApp: () -> Unit) {
    VivacCard {
        Row(
            Modifier.fillMaxSize().padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            Button(app?.label ?: "Abrir", onOpenApp) { app?.let { Box(Modifier.size(26.dp), contentAlignment = Alignment.Center) { AppFace(it, Ink.onPrimary) } } }
            shortcuts.take(5).forEach { s ->
                Button(s.label, { onShortcut(s.id) }) { LineIcon(ShortcutGlyph.of(s.label).path, Ink.text, 20.dp) }
            }
        }
    }
}

@Composable
private fun Button(label: String, onClick: () -> Unit, icon: @Composable () -> Unit) {
    Column(
        Modifier
            .clip(RoundedCornerShape(14.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = label }
            .padding(horizontal = 2.dp, vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            Modifier.size(40.dp).clip(CircleShape).background(if (label == "Abrir") Ink.primary else Ink.raised).border(1.dp, Ink.field, CircleShape),
            contentAlignment = Alignment.Center,
        ) { icon() }
        Text(label, style = Type.cota.copy(fontSize = 9.sp), maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

/** The header's height and each chat's, in dp, to work out how many chats fit. */
private const val HEADER = 34f
private const val ROW = 58f
