package dev.vivac.launcher.campamento

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.petate.Pack
import dev.vivac.launcher.theme.AppTile
import dev.vivac.launcher.theme.Contours
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Monogram
import dev.vivac.launcher.theme.Type
import dev.vivac.launcher.theme.ropeStroke

@Composable
fun CampamentoScreen(
    stamp: String,
    facts: PhoneFacts,
    apps: List<InstalledApp>,
    onOpenApp: (String) -> Unit,
    onAppInfo: (String) -> Unit,
    onOpenPetate: (search: Boolean) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenAbout: () -> Unit,
) {
    Box(Modifier.fillMaxSize().background(Ink.surface)) {
        Contours(Modifier.fillMaxSize())
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Header(stamp, onOpenSettings)
            CordadaCard()
            ViaCard(facts, onOpenAbout)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FactTile("almacenamiento", "${facts.freeGb} GB", "libres de ${facts.totalGb} GB", Modifier.weight(1f))
                FactTile("batería", "${facts.batteryPercent} %", if (facts.charging) "cargando" else "sin cargar", Modifier.weight(1f))
            }
            Spacer(Modifier.weight(1f))
            DockRow(apps, onOpenApp, onAppInfo) { onOpenPetate(false) }
            SearchPill { onOpenPetate(true) }
        }
    }
}

@Composable
private fun Header(stamp: String, onOpenSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.Bottom) {
        Column(Modifier.weight(1f)) {
            Text(stamp.uppercase(), style = Type.cota)
            Text("Campamento", style = Type.title, modifier = Modifier.semantics { heading() })
        }
        Box(
            Modifier
                .size(44.dp)
                .clip(CircleShape)
                .border(1.5.dp, Ink.borderControl, CircleShape)
                .clickable(role = Role.Button, onClickLabel = "Abrir ajustes", onClick = onOpenSettings)
                .semantics { contentDescription = "Ajustes del sistema" },
            contentAlignment = Alignment.Center,
        ) { LineIcon(Glyph.SLIDERS, Ink.text, 22.dp) }
    }
}

private data class RopeNode(val name: String, val x: Float, val y: Float, val tied: Boolean)

/** Motif 4: the rope. Only this phone is tied until the link with the PC exists, so the rest hangs dashed. */
@Composable
private fun CordadaCard() {
    val nodes = listOf(
        RopeNode("móvil", 16f, 22f, tied = true),
        RopeNode("pc", 112f, 48f, tied = false),
        RopeNode("pi", 160f, 34f, tied = false),
        RopeNode("win11", 206f, 22f, tied = false),
        RopeNode("lab", 302f, 46f, tied = false),
    )
    val tied = nodes.count { it.tied }
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("LA CORDADA", style = Type.cota, modifier = Modifier.weight(1f))
            Text("$tied de ${nodes.size} atados", style = Type.mono, color = if (tied == nodes.size) Ink.okText else Ink.textMuted)
        }
        BoxWithConstraints(
            Modifier
                .fillMaxWidth()
                .height(70.dp)
                .semantics { contentDescription = "Cordada: solo este móvil atado; el enlace con el PC aún no está hecho" },
        ) {
            val kd = maxWidth.value / 318f
            Canvas(Modifier.fillMaxSize()) {
                val k = size.width / 318f
                val rope = Path().apply {
                    moveTo(16f * k, 22f * k)
                    cubicTo(60f * k, 22f * k, 70f * k, 48f * k, 112f * k, 48f * k)
                    cubicTo(154f * k, 48f * k, 170f * k, 20f * k, 206f * k, 22f * k)
                    cubicTo(242f * k, 24f * k, 262f * k, 46f * k, 302f * k, 46f * k)
                }
                drawPath(rope, Ink.borderControl, style = ropeStroke(tied = false, density = density))
                nodes.forEach { n ->
                    val c = Offset(n.x * k, n.y * k)
                    drawCircle(Ink.field, radius = 11.dp.toPx(), center = c)
                    drawCircle(
                        if (n.tied) Ink.ok else Ink.borderControl,
                        radius = 10.dp.toPx(),
                        center = c,
                        style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx()),
                    )
                }
            }
            nodes.forEach { n ->
                Text(
                    n.name,
                    style = Type.mono.copy(fontSize = 10.sp, lineHeight = 14.sp, textAlign = TextAlign.Center),
                    color = if (n.tied) Ink.text else Ink.textMuted,
                    modifier = Modifier
                        .offset(x = (n.x * kd - 26f).dp, y = (n.y * kd + 12f).dp)
                        .width(52.dp),
                )
            }
        }
    }
}

@Composable
private fun ViaCard(facts: PhoneFacts, onOpenAbout: () -> Unit) {
    Card(Modifier.clickable(role = Role.Button, onClickLabel = "Ver información del teléfono", onClick = onOpenAbout)) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            // The pitch gauge: full means "at the summit", this phone is up to date with its own channel.
            Box(
                Modifier
                    .width(10.dp)
                    .height(76.dp)
                    .clip(RoundedCornerShape(5.dp))
                    .background(Ink.surface),
                contentAlignment = Alignment.BottomCenter,
            ) { Box(Modifier.fillMaxWidth().fillMaxHeight().background(Ink.measure)) }
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("LA VÍA · GRAPHENEOS", style = Type.cota)
                Text(facts.build, style = Type.figure.copy(fontSize = 28.sp, lineHeight = 36.sp), color = Ink.measure)
                Text("parche de seguridad del ${facts.securityPatch}", style = Type.small.copy(fontSize = 14.sp))
            }
        }
    }
}

@Composable
private fun FactTile(caption: String, figure: String, detail: String, modifier: Modifier) {
    Column(
        modifier.clip(RoundedCornerShape(20.dp)).background(Ink.raised).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(caption.uppercase(), style = Type.cota)
        Text(figure, style = Type.figure)
        Text(detail, style = Type.small)
    }
}

@Composable
private fun DockRow(apps: List<InstalledApp>, onOpenApp: (String) -> Unit, onAppInfo: (String) -> Unit, onOpenPetate: () -> Unit) {
    val byPackage = apps.associateBy { it.packageName }
    val slots = Dock.pick(byPackage.keys)
    // Five equal columns: on a 412dp Pixel five fixed 76dp tiles do not fit and labels got clipped.
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        slots.forEach { slot ->
            when (slot) {
                is DockSlot.App -> {
                    val app = byPackage.getValue(slot.packageName)
                    val deep = app.packageName == "com.termux"
                    AppTile(
                        label = app.label,
                        background = if (deep) Ink.deep else Ink.field,
                        onClick = { onOpenApp(app.packageName) },
                        onLongClick = { onAppInfo(app.packageName) },
                        modifier = Modifier.weight(1f),
                    ) { Monogram(Pack.monogram(app), if (deep) Ink.ok else Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]) }
                }
                DockSlot.Petate -> AppTile(label = "Petate", background = Ink.field, onClick = onOpenPetate, modifier = Modifier.weight(1f)) {
                    LineIcon(Glyph.GRID, Ink.text)
                }
            }
        }
    }
}

@Composable
private fun SearchPill(onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(bottom = 12.dp)
            .height(52.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(Ink.field)
            .clickable(role = Role.Button, onClickLabel = "Buscar en el petate", onClick = onClick)
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        LineIcon(Glyph.PROMPT, Ink.accentText, 20.dp)
        Text("buscar en el petate…", style = TextStyle(fontFamily = Type.mono.fontFamily, fontSize = 14.sp), color = Ink.textMuted)
    }
}

@Composable
private fun Card(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(Ink.raised)
            .then(modifier)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) { content() }
}
