package dev.vivac.launcher.ajustes

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.core.Gesture
import dev.vivac.launcher.theme.Brand
import dev.vivac.launcher.theme.Contours
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.Type

/** Everything vivac lets you choose, as the settings screen shows it. */
data class SettingsState(
    val locked: Boolean,
    val wallpaper: Boolean,
    val labels: Boolean,
    val columns: Int,
    val dotsAllowed: Boolean,
    val counts: Boolean,
    val swipeUp: Gesture,
    val swipeDown: Gesture,
    val doubleTapLock: Boolean,
    val isHome: Boolean,
)

/** What each choice on the settings screen does. */
class SettingsActions(
    val toggleLock: () -> Unit = {},
    val toggleWallpaper: () -> Unit = {},
    val changeWallpaper: () -> Unit = {},
    val toggleLabels: () -> Unit = {},
    val setColumns: (Int) -> Unit = {},
    val allowDots: () -> Unit = {},
    val toggleCounts: () -> Unit = {},
    val setSwipeUp: (Gesture) -> Unit = {},
    val setSwipeDown: (Gesture) -> Unit = {},
    val toggleDoubleTap: () -> Unit = {},
    val backUp: () -> Unit = {},
    val restore: () -> Unit = {},
    val becomeHome: () -> Unit = {},
    val close: () -> Unit = {},
)

/** vivac's settings: one screen, grouped as the camp is (home, petate, notices, gestures, copies). */
@Composable
fun SettingsScreen(state: SettingsState, act: SettingsActions) {
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
                Text("VIVAC · AJUSTES", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.weight(1f))
                Choice("Cerrar", on = false, onClick = act.close)
            }
            Text("Ajustes", style = Type.title.copy(fontSize = 44.sp, lineHeight = 46.sp, letterSpacing = (-0.04).em, color = Brand.papel50), modifier = Modifier.semantics { heading() })

            Section("CAMPAMENTO")
            if (!state.isHome) Toggle("vivac como app de inicio", "Ahora usas otra; los atajos y «Añadir a inicio» solo llegan a la app de inicio.", false, act.becomeHome)
            Toggle("Bloquear el campamento", "Nada se arrastra mientras esté bloqueado.", state.locked, act.toggleLock)
            Toggle("Fondo del teléfono", "Tu fondo de pantalla detrás, con el velo de la noche encima.", state.wallpaper, act.toggleWallpaper)
            if (state.wallpaper) Action("Cambiar el fondo de pantalla", act.changeWallpaper)
            Toggle("Nombres bajo las apps", "Sin nombres, TalkBack los sigue leyendo.", state.labels, act.toggleLabels)

            Section("PETATE")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Columnas", style = Type.body, modifier = Modifier.weight(1f))
                listOf(4, 5).forEach { n -> Choice("$n", state.columns == n) { act.setColumns(n) } }
            }

            Section("AVISOS")
            if (!state.dotsAllowed) Action("Activar los puntos de aviso", act.allowDots)
            Toggle("Número de avisos", "En vez del punto, cuántos tiene cada app.", state.counts, act.toggleCounts)

            Section("GESTOS")
            GestureRow("Deslizar hacia arriba", state.swipeUp, act.setSwipeUp)
            GestureRow("Deslizar hacia abajo", state.swipeDown, act.setSwipeDown)
            Toggle("Doble toque apaga la pantalla", "Usa el servicio de accesibilidad de vivac, que no lee nada.", state.doubleTapLock, act.toggleDoubleTap)

            Section("COPIA")
            Action("Guardar una copia del campamento", act.backUp)
            Action("Restaurar una copia", act.restore)
        }
    }
}

@Composable
private fun Section(title: String) {
    Text(title, style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.padding(top = 14.dp).semantics { heading() })
}

@Composable
private fun Toggle(title: String, detail: String, on: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.surface)
            .clickable(role = Role.Switch, onClick = onClick)
            .semantics(mergeDescendants = true) { selected = on }
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Type.body)
            Text(detail, style = Type.small)
        }
        // On: a coral bar with its word, never colour alone.
        Text(
            if (on) "SÍ" else "NO",
            style = Type.cota.copy(fontSize = 11.sp, color = if (on) Ink.deep else Ink.text),
            modifier = Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(if (on) Ink.primary else Ink.deep)
                .border(1.5.dp, if (on) Ink.primary else Ink.borderControl, RoundedCornerShape(999.dp))
                .padding(horizontal = 12.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun Action(title: String, onClick: () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.surface)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.CenterStart,
    ) { Text(title, style = Type.body.copy(color = Ink.accentText)) }
}

@Composable
private fun GestureRow(title: String, current: Gesture, onPick: (Gesture) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = Type.body)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Gesture.entries.forEach { g -> Choice(g.title, current == g) { onPick(g) } }
        }
    }
}

@Composable
private fun Choice(text: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .heightIn(min = 44.dp)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { selected = on },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            style = Type.body.copy(color = if (on) Ink.deep else Ink.text),
            modifier = Modifier
                .height(36.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(if (on) Ink.primary else Ink.deep)
                .border(1.5.dp, if (on) Ink.primary else Ink.borderControl, RoundedCornerShape(999.dp))
                .padding(horizontal = 14.dp, vertical = 7.dp),
        )
    }
}
