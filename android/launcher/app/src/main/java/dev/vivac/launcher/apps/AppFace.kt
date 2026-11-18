package dev.vivac.launcher.apps

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import dev.vivac.launcher.core.IconStyle
import dev.vivac.launcher.petate.Pack
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Monogram

/**
 * What sits inside a tile. By default vivac's glyph for the app in the tile's tone (else its monogram); if you
 * chose another icon style, that icon, falling back to the glyph when the app has none in that style.
 */
@Composable
fun AppFace(app: InstalledApp, tone: Color) {
    // Decorative: the tile's label already names the app for TalkBack.
    val choice = LocalIconChoice.current
    val icons = LocalAppIcons.current
    val image by produceState<ImageBitmap?>(null, app.packageName, choice, icons) {
        value = if (icons == null || choice.style == IconStyle.GLYPHS) null else icons.load(app.packageName, choice)
    }
    val icon = image
    when {
        icon == null -> Glyph(app, tone)
        choice.style == IconStyle.THEMED -> Image(icon, null, Modifier.size(40.dp).testTag("icon:themed"), colorFilter = ColorFilter.tint(tone))
        else -> Image(icon, null, Modifier.size(44.dp).testTag("icon:image"))
    }
}

@Composable
private fun Glyph(app: InstalledApp, tone: Color) {
    val glyph = Glyphs.of(app.packageName)
    if (glyph != null) LineIcon(glyph, tone, 30.dp) else Monogram(Pack.monogram(app), tone)
}
