package dev.vivac.launcher.apps

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.unit.dp
import dev.vivac.launcher.petate.Pack
import dev.vivac.launcher.theme.Monogram

/** Provided once by the activity, so every tile shares one icon cache. */
val LocalAppIcons = staticCompositionLocalOf<AppIcons?> { null }

/** What sits inside a tile: the themed glyph in the tile's tone, else the colour icon, else the monogram. */
@Composable
fun AppFace(app: InstalledApp, tone: Color) {
    val icons = LocalAppIcons.current
    val icon by produceState<AppIcon?>(null, app.packageName, icons) { value = icons?.load(app.packageName) }
    when (val i = icon) {
        // Decorative: the tile's label already names the app for TalkBack.
        is AppIcon.Glyph -> Image(i.image, contentDescription = null, colorFilter = ColorFilter.tint(tone), modifier = Modifier.size(48.dp))
        is AppIcon.Full -> Image(i.image, contentDescription = null, modifier = Modifier.size(44.dp))
        null -> Monogram(Pack.monogram(app), tone)
    }
}
