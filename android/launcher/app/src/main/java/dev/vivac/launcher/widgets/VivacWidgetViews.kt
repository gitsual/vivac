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

/**
 * At a glance: the next alarm and the next event, each a tap away from its app, and what is playing with its
 * three buttons. Says so when there is nothing to show.
 */
@Composable
fun GlanceWidget(
    glance: dev.vivac.launcher.core.Glance,
    playing: dev.vivac.launcher.core.NowPlaying?,
    playingApp: InstalledApp?,
    onAlarm: () -> Unit,
    onEvent: (dev.vivac.launcher.core.CalendarEvent) -> Unit,
    onPlaying: () -> Unit,
    onMedia: (dev.vivac.launcher.core.Media) -> Unit,
) {
    VivacCard {
        Column(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("DE UN VISTAZO", style = Type.cota.copy(fontSize = 10.sp))
            if (glance.nextAlarm == null && glance.nextEvent == null && playing == null) {
                Text("Nada a la vista.", style = Type.small)
            }
            glance.nextAlarm?.let { at ->
                GlanceLine(ALARM, "Alarma · " + dev.vivac.launcher.petate.When.of(at), onAlarm)
            }
            glance.nextEvent?.let { e ->
                GlanceLine(EVENT, e.title, { onEvent(e) }, detail = dev.vivac.launcher.petate.When.of(e.startMillis))
            }
            playing?.let { p ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(
                        Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = onPlaying),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) { playingApp?.let { AppFace(it, Ink.primary) } }
                        Column(Modifier.weight(1f)) {
                            Text(p.title, style = Type.body.copy(fontSize = 14.sp, lineHeight = 17.sp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            if (p.artist.isNotBlank()) Text(p.artist, style = Type.small, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    MediaButton("Anterior", PREVIOUS) { onMedia(dev.vivac.launcher.core.Media.PREVIOUS) }
                    MediaButton(if (p.playing) "Pausa" else "Reproducir", if (p.playing) PAUSE else PLAY) { onMedia(dev.vivac.launcher.core.Media.TOGGLE) }
                    MediaButton("Siguiente", NEXT) { onMedia(dev.vivac.launcher.core.Media.NEXT) }
                }
            }
        }
    }
}

@Composable
private fun GlanceLine(glyph: String, text: String, onClick: () -> Unit, detail: String? = null) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = onClick).padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LineIcon(glyph, Ink.accentText, 18.dp)
        Text(text, style = Type.body.copy(fontSize = 14.sp, lineHeight = 17.sp), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        detail?.let { Text(it, style = Type.cota.copy(fontSize = 10.sp)) }
    }
}

@Composable
private fun MediaButton(label: String, glyph: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(Ink.raised)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { LineIcon(glyph, Ink.text, 16.dp) }
}

private const val ALARM = "M3.5 13a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0 -17 0 M12 9v4l3 2 M5 3 2 6 M19 3l3 3"
private const val EVENT = "M4 6h16v14H4z M4 10h16 M8 3v5 M16 3v5"
private const val PREVIOUS = "M6 5v14 M19 5l-10 7 10 7z"
private const val NEXT = "M18 5v14 M5 5l10 7-10 7z"
private const val PLAY = "M7 5l12 7-12 7z"
private const val PAUSE = "M8 5v14 M16 5v14"

/** The header's height and each chat's, in dp, to work out how many chats fit. */
private const val HEADER = 34f
private const val ROW = 58f
