package dev.vivac.launcher.ajustes

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
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.core.SystemPage
import dev.vivac.launcher.theme.Brand
import dev.vivac.launcher.theme.Contours
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Type

/**
 * vivac's settings hub: the phone's settings by name, each opening Android's page for it, and vivac's own first.
 * [facts] is a line about the phone now (battery, storage).
 */
@Composable
fun SystemScreen(facts: String, onPage: (SystemPage) -> Unit, onVivac: () -> Unit, onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Ink.deep)) {
        Contours(Modifier.fillMaxSize(), color = Ink.surface)
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("VIVAC · TELÉFONO", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.weight(1f))
                Text(
                    "Cerrar",
                    style = Type.body,
                    modifier = Modifier
                        .heightIn(min = 44.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .clickable(role = Role.Button, onClick = onClose)
                        .border(1.dp, Ink.borderControl, RoundedCornerShape(999.dp))
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                )
            }
            Text("Teléfono", style = Type.title.copy(fontSize = 44.sp, lineHeight = 46.sp, letterSpacing = (-0.04).em, color = Brand.papel50), modifier = Modifier.semantics { heading() })
            if (facts.isNotBlank()) Text(facts, style = Type.cota.copy(fontSize = 12.sp))
            Text("VIVAC", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.padding(top = 10.dp).semantics { heading() })
            Line("Ajustes de vivac", "Campamento, iconos, petate, gestos, copias", accent = true, onClick = onVivac)
            Text("ANDROID", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.padding(top = 10.dp).semantics { heading() })
            SystemPage.hub.forEach { page -> Line(page.title, page.detail) { onPage(page) } }
        }
    }
}

@Composable
private fun Line(title: String, detail: String, accent: Boolean = false, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.surface)
            .border(1.dp, if (accent) Ink.primary else Ink.field, RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Type.body.copy(color = if (accent) Ink.accentText else Ink.text))
            Text(detail, style = Type.small)
        }
        LineIcon(Glyph.ARROW, Ink.textMuted, 18.dp)
    }
}
