package dev.vivac.launcher.apps

import android.content.Context
import android.content.pm.LauncherApps
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Process
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * An app's icon as vivac draws it: always one ink, tinted with the tile's tone, so every tile shares the
 * same look. Apps that cannot give one get vivac's monogram instead (a null icon), never their colour icon.
 */
sealed interface AppIcon {
    /** A one-ink glyph: the app's themed layer, or a silhouette vivac cut from its foreground. */
    data class Glyph(val image: ImageBitmap) : AppIcon
}

/** Adapter: loads icons off the main thread and keeps them in memory. [find] gives an app's raw icon. */
class AppIcons(context: Context, private val find: (packageName: String) -> Drawable?) {
    /** Icons as LauncherApps gives them for the current profile. */
    constructor(context: Context) : this(context, { pkg ->
        context.getSystemService(LauncherApps::class.java).getActivityList(pkg, Process.myUserHandle()).firstOrNull()?.getIcon(0)
    })

    private val density = context.resources.displayMetrics.density
    private val cache = LruCache<String, AppIcon>(256)

    suspend fun load(packageName: String): AppIcon? {
        cache.get(packageName)?.let { return it }
        return withContext(Dispatchers.IO) {
            val drawable = find(packageName) ?: return@withContext null
            render(drawable)?.also { cache.put(packageName, it) }
        }
    }

    /** Drop cached icons, e.g. after an app update changes its icon. */
    fun forget(packageName: String) {
        cache.remove(packageName)
    }

    private fun render(drawable: Drawable): AppIcon? {
        val adaptive = drawable as? AdaptiveIconDrawable ?: return null
        // A 108-unit adaptive layer drawn at 48dp shows its 72-unit visible area at 32dp, the glyph size of the design.
        val layerPx = (48 * density).toInt()
        val mono = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) adaptive.monochrome else null
        // Some apps (Google Drive) ship a themed layer that renders fully transparent here.
        mono?.toBitmap(layerPx, layerPx)?.takeIf { it.coverage() > 0f }?.let { return AppIcon.Glyph(it.asImageBitmap()) }
        // No themed layer: the foreground's silhouette, unless it is a solid block (no drawing to keep) or empty.
        val fg = adaptive.foreground?.toBitmap(layerPx, layerPx) ?: return null
        return fg.takeIf { it.coverage() in MIN_INK..MAX_INK }?.let { AppIcon.Glyph(it.asImageBitmap()) }
    }

    /** Share of the visible (central 72 of 108 units) area that is inked, sampling every 4th pixel per axis. */
    private fun Bitmap.coverage(): Float {
        val inset = width / 6
        var inked = 0
        var seen = 0
        for (y in inset until height - inset step 4) for (x in inset until width - inset step 4) {
            seen++
            if (Color.alpha(getPixel(x, y)) > 24) inked++
        }
        return if (seen == 0) 0f else inked.toFloat() / seen
    }

    private companion object {
        /** Below this the silhouette is empty; above it the foreground is a block with nothing drawn to keep. */
        const val MIN_INK = 0.02f
        const val MAX_INK = 0.6f
    }
}
