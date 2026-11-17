package dev.vivac.launcher.apps

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import dev.vivac.launcher.petate.Pack
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Monogram

/** What sits inside a tile: vivac's glyph for the app in the tile's tone, else its monogram. Never the app's own icon. */
@Composable
fun AppFace(app: InstalledApp, tone: Color) {
    // Decorative: the tile's label already names the app for TalkBack.
    val glyph = Glyphs.of(app.packageName)
    if (glyph != null) LineIcon(glyph, tone, 30.dp) else Monogram(Pack.monogram(app), tone)
}
